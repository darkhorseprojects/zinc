local json = require("lunajson")
local make_model = require("src.model")
local make_run = require("src.run")

local NULL = {}

local function decode(source, maximum)
    assert(type(source) == "string" and (not maximum or #source <= maximum) and utf8.len(source), "invalid JSON bytes")
    local value, offset = json.decode(source, 1, NULL)
    assert(source:sub(offset):match("^%s*$"), "JSON has trailing data")
    return value
end

local function object(source, fields, maximum)
    assert(source:match("^%s*{"), "JSON value must be an object")
    local value = decode(source, maximum)
    assert(type(value) == "table", "JSON value must be an object")
    for key in pairs(value) do
        assert(fields[key], "unknown JSON field")
    end
    return value
end

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
    return table.concat(output, "\n")
end

local function request(value, nested)
    assert(type(value) == "table", "invalid Zinc request")
    local fields = { question = true, parent = true, memory = true }
    if nested then
        fields.preset = true
    end
    for key in pairs(value) do
        assert(fields[key], "unknown Zinc request field")
    end
    assert(type(value.question) == "string" and value.question ~= "" and utf8.len(value.question), "invalid question")
    assert(value.parent == nil or math.type(value.parent) == "integer" and value.parent > 0, "invalid parent")
    assert(math.type(value.memory) == "integer" and value.memory >= 0, "invalid memory")
    assert(not nested or value.preset == nil or type(value.preset) == "string", "invalid preset")
    return value
end

local function merge(defaults, overrides, path)
    assert(type(overrides) == "table" and overrides ~= NULL, "invalid " .. path)
    local output = {}
    for name, value in pairs(defaults) do
        local selected = overrides[name]
        if selected == nil then
            selected = value
        end
        local field = path .. "." .. name
        if type(value) == "table" then
            output[name] = merge(value, selected, field)
        elseif type(value) == "number" then
            assert(math.type(selected) == "integer" and selected >= 0, "invalid " .. field)
            if not path:find("^config%.retrieval") then
                assert(selected > 0, "invalid " .. field)
            end
            output[name] = selected
        else
            assert(
                type(selected) == type(value) and (type(selected) ~= "string" or selected ~= ""),
                "invalid " .. field
            )
            output[name] = selected
        end
    end
    for name in pairs(overrides) do
        assert(defaults[name] ~= nil, "unknown " .. path .. " field")
    end
    return output
end

return function(spec)
    local documents = { base = document_text(spec.document), presets = {} }
    local union = {}
    for name, preset in pairs(spec.presets) do
        documents.presets[name] = document_text(preset.document)
        for member in pairs(preset.members) do
            union[member] = true
        end
    end

    local function configuration(source)
        local value = object(source, {
            version = true,
            actor = true,
            preset = true,
            parent = true,
            memory = true,
            run = true,
            models = true,
            retrieval = true,
        }, spec.limits.config_bytes)
        assert(value.version == 1, "unsupported Zinc config version")
        assert(type(value.actor) == "string" and value.actor ~= "" and utf8.len(value.actor), "invalid actor")
        assert(spec.presets[value.preset], "unknown Zinc preset")
        local coordinates = value.parent ~= nil or value.memory ~= nil
        assert(
            not coordinates or value.parent ~= nil and value.memory ~= nil,
            "parent and memory must be configured together"
        )
        assert(
            value.parent == nil or value.parent == NULL or math.type(value.parent) == "integer" and value.parent > 0,
            "invalid parent"
        )
        assert(value.memory == nil or math.type(value.memory) == "integer" and value.memory >= 0, "invalid memory")
        local selected = merge(spec.defaults, {
            run = value.run or {},
            models = value.models or {},
            retrieval = value.retrieval or {},
        }, "config")
        assert(
            selected.models.rerank.passage_tokens > 0 and selected.models.rerank.query_tokens > 0,
            "invalid reranker limits"
        )
        value.run, value.models, value.retrieval = selected.run, selected.models, selected.retrieval
        return value
    end

    local entry, runner = {}, nil

    function entry.document(input, opaque)
        configuration(opaque)
        assert(input == "", "document takes empty input")
        return documents.base
    end

    function entry.design(input, opaque)
        configuration(opaque)
        assert(input == "", "design takes empty input")
        return document_text(spec.design)
    end

    for name in pairs(union) do
        local member = name
        entry[member] = function(value, opaque)
            local config = configuration(opaque)
            local descriptor = assert(spec.presets[config.preset].members[member], member .. " is unavailable")
            assert(
                type(value) == "table" and type(value.action) == "string" and type(value.arguments) == "table",
                "invalid capability call"
            )
            return descriptor.call(value.action, value.arguments)
        end
    end

    function entry.zinc_call(value, opaque)
        local config = configuration(opaque)
        assert(type(value) == "table" and math.type(value.caller) == "integer", "invalid Zinc caller")
        local call, final = runner:nested(config, value.caller, request(value.arguments[1], true))
        return { branch = call.branch, id = final.id, parent = final.parent, memory = final.memory, text = final.text }
    end

    function entry.zinc_destroy(value, opaque)
        local config = configuration(opaque)
        assert(type(value) == "table" and math.type(value.caller) == "integer", "invalid Zinc caller")
        local branch = value.arguments and value.arguments[1]
        assert(math.type(branch) == "integer" and branch > 0, "invalid branch")
        return runner:destroy(config.actor, value.caller, branch)
    end

    local function invoke(input, opaque)
        assert(
            type(input) == "string" and input ~= "" and #input <= spec.limits.request_bytes and utf8.len(input),
            "invalid Zinc input"
        )
        local config = configuration(opaque)
        local automatic = config.parent == nil
        local parent = config.parent == NULL and nil or config.parent
        local call, final = runner:root({
            actor = config.actor,
            automatic = automatic,
            config = config,
            memory = automatic and nil or config.memory,
            parent = parent,
            preset = spec.presets[config.preset],
            preset_name = config.preset,
            question = input,
            quota = config.run.quota_tokens,
        })
        return final.text
            .. "\n\n-# result #"
            .. final.id
            .. " · start #"
            .. call.start
            .. " · parent "
            .. (final.parent and "#" .. final.parent or "none")
            .. " · memory #"
            .. final.memory
    end

    runner = make_run(spec, entry, make_model, documents)
    return setmetatable(entry, {
        __call = function(_, input, opaque)
            return invoke(input, opaque)
        end,
        __metatable = false,
    })
end
