local json = require("src.json")
local make_model = require("src.model")
local make_run = require("src.run")

local function document_text(document)
    local output = {}
    local function collect(value)
        if type(value) == "string" then
            output[#output + 1] = value
        elseif type(value) == "table" then
            for index = 1, #value do
                collect(value[index])
            end
            local keys = {}
            for key in pairs(value) do
                if type(key) == "string" then
                    keys[#keys + 1] = key
                end
            end
            table.sort(keys)
            for _, key in ipairs(keys) do
                collect(value[key])
            end
        end
    end
    collect(document)
    return table.concat(output, "\n\n")
end

return function(spec)
    assert(
        type(spec) == "table" and type(spec.document) == "table" and type(spec.design) == "table",
        "invalid Zinc specification"
    )
    assert(
        type(spec.model) == "table" and type(spec.store) == "table" and type(spec.memory) == "table",
        "invalid Zinc specification"
    )
    assert(type(spec.limits) == "table" and type(spec.presets) == "table", "invalid Zinc specification")

    local members, preset_documents = {}, {}
    for _, preset_name in ipairs({ "unsafe", "safe", "no-host" }) do
        local preset = spec.presets[preset_name]
        assert(type(preset) == "table" and type(preset.document) == "table", "invalid preset")
        assert(type(preset.members) == "table", "invalid preset members")
        for key in pairs(preset) do
            assert(key == "document" or key == "members", "unknown preset field")
        end
        preset_documents[preset_name] = document_text(preset.document)
        for name, member in pairs(preset.members) do
            assert(type(name) == "string" and name ~= "" and utf8.len(name), "invalid member name")
            assert(name ~= "document" and name ~= "design" and name ~= "zinc" and name ~= "pa", "reserved member name")
            assert(type(member) == "table" and type(member.call) == "function", "invalid preset member")
            assert(
                type(member.prompt) == "string" and member.prompt ~= "" and utf8.len(member.prompt),
                "invalid member prompt"
            )
            for key in pairs(member) do
                assert(key == "call" or key == "prompt", "unknown member field")
            end
            members[name] = true
        end
    end

    local limit_names = { "request_bytes", "config_bytes", "record_bytes", "tool_result_bytes", "model_rounds" }
    for _, name in ipairs(limit_names) do
        assert(math.type(spec.limits[name]) == "integer" and spec.limits[name] > 0, "invalid limit: " .. name)
    end
    for key in pairs(spec.limits) do
        local known = false
        for _, name in ipairs(limit_names) do
            known = known or key == name
        end
        assert(known, "unknown limit: " .. tostring(key))
    end
    local memory_limits = {
        "chronological_records",
        "chronological_tokens",
        "semantic_terms",
        "grounding_tokens",
        "exact_forms",
        "candidates",
        "semantic_tokens",
    }
    assert(type(spec.memory.cygnet) == "string" and spec.memory.cygnet ~= "", "invalid Cygnet path")
    assert(
        type(spec.memory.semantic_language) == "string" and spec.memory.semantic_language ~= "",
        "invalid semantic language"
    )
    assert(
        math.type(spec.memory.semantic_depth) == "integer" and spec.memory.semantic_depth >= 0,
        "invalid semantic depth"
    )
    local cutoff = spec.memory.semantic_attention_cutoff
    assert(
        type(cutoff) == "number" and cutoff == cutoff and cutoff ~= math.huge and cutoff ~= -math.huge,
        "invalid semantic cutoff"
    )
    for _, name in ipairs(memory_limits) do
        assert(math.type(spec.memory[name]) == "integer" and spec.memory[name] > 0, "invalid memory limit: " .. name)
    end
    assert(spec.model.chat.maximum_output_tokens < spec.model.chat.context_tokens, "invalid model context")
    assert(spec.limits.record_bytes >= spec.model.chat.maximum_tool_source_bytes, "tool source exceeds record limit")
    assert(spec.limits.record_bytes >= spec.limits.tool_result_bytes, "tool result exceeds record limit")

    local cached_source, cached_config, cached_preset
    local function configuration(source)
        assert(
            type(source) == "string" and #source <= spec.limits.config_bytes and utf8.len(source),
            "invalid Zinc config"
        )
        if source == cached_source then
            return cached_config, cached_preset
        end
        local value = json.object(source, { version = true, actor = true, preset = true, imports = true })
        assert(value.version == 1, "unsupported Zinc config version")
        assert(
            type(value.actor) == "string" and value.actor ~= "" and utf8.len(value.actor),
            "actor must be nonempty UTF-8"
        )
        local preset = spec.presets[value.preset]
        assert(preset, "unknown Zinc preset")
        assert(type(value.imports) == "table", "imports must be an object")
        for name, prompt in pairs(value.imports) do
            assert(type(name) == "string" and name ~= "" and name ~= "pa" and utf8.len(name), "invalid Import name")
            assert(type(prompt) == "string" and prompt ~= "" and utf8.len(prompt), "invalid Import prompt")
        end
        cached_source, cached_config, cached_preset = source, value, preset
        return value, preset
    end

    local entry, runner = {}, nil
    local zinc_text, design_text = document_text(spec.document), document_text(spec.design)

    function entry.document(input, opaque)
        configuration(opaque)
        assert(input == "", "document takes empty input")
        return zinc_text
    end

    function entry.design(input, opaque)
        configuration(opaque)
        assert(input == "", "design takes empty input")
        return design_text
    end

    for name in pairs(members) do
        entry[name] = function(input, opaque)
            local _, preset = configuration(opaque)
            local member = preset.members[name]
            assert(member, name .. " is unavailable")
            return member.call(input)
        end
    end

    local function invoke(input, opaque)
        assert(
            type(input) == "string" and #input <= spec.limits.request_bytes and utf8.len(input),
            "invalid Zinc input"
        )
        local config, preset = configuration(opaque)
        local request = json.object(input, { question = true, parent = true, memory = true })
        assert(
            type(request.question) == "string" and request.question ~= "" and utf8.len(request.question),
            "question must be nonempty UTF-8"
        )
        assert(
            request.parent == json.null or math.type(request.parent) == "integer" and request.parent > 0,
            "parent must be null or positive"
        )
        assert(math.type(request.memory) == "integer" and request.memory >= 0, "memory must be nonnegative")
        local parent
        if request.parent ~= json.null then
            parent = request.parent
        end
        local final = runner({
            actor = config.actor,
            imports = config.imports,
            input = input,
            parent = parent,
            memory = request.memory,
            preset = preset,
            question = request.question,
        })
        return json.encode({
            id = final.id,
            parent = final.parent or json.null,
            memory = final.memory,
            text = final.text,
        })
    end

    function entry.zinc(input, opaque)
        return invoke(input, opaque)
    end

    local model = make_model(spec.model)
    runner = make_run(spec, entry, model, { zinc = zinc_text, presets = preset_documents })
    return setmetatable(entry, {
        __call = function(_, input, opaque)
            return invoke(input, opaque)
        end,
        __metatable = false,
    })
end
