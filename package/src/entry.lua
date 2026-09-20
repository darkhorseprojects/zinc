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

local function native(value, null)
    if value == null then
        return nil
    end
    if type(value) ~= "table" then
        return value
    end
    local output = {}
    for key, item in pairs(value) do
        output[key] = native(item, null)
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
        local value = object(
            source,
            { version = true, actor = true, preset = true, quota = true, imports = true },
            spec.limits.config_bytes
        )
        assert(value.version == 1, "unsupported Zinc config version")
        assert(type(value.actor) == "string" and value.actor ~= "" and utf8.len(value.actor), "invalid actor")
        assert(spec.presets[value.preset], "unknown Zinc preset")
        assert(value.quota == NULL or math.type(value.quota) == "integer" and value.quota > 0, "invalid quota")
        assert(type(value.imports) == "table", "invalid Imports")
        for name, description in pairs(value.imports) do
            assert(type(name) == "string" and name ~= "" and name ~= "pa" and utf8.len(name), "invalid Import name")
            assert(
                type(description) == "string" and description ~= "" and utf8.len(description),
                "invalid Import description"
            )
        end
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
        local call, final = runner:nested(config.actor, config.imports, value.caller, request(value.arguments[1], true))
        return {
            branch = call.branch,
            id = final.id,
            parent = final.parent,
            memory = final.memory,
            text = final.text,
        }
    end

    function entry.zinc_destroy(value, opaque)
        local config = configuration(opaque)
        assert(type(value) == "table" and math.type(value.caller) == "integer", "invalid Zinc caller")
        local branch = value.arguments and value.arguments[1]
        assert(math.type(branch) == "integer" and branch > 0, "invalid branch")
        return runner:destroy(config.actor, value.caller, branch)
    end

    function entry.agent(value, opaque)
        local config = configuration(opaque)
        assert(type(value) == "table" and math.type(value.caller) == "integer", "invalid Agent caller")
        local name, call = value.arguments and value.arguments[1], value.arguments and value.arguments[2]
        assert(type(name) == "string" and config.imports[name], "unknown Import")
        runner:authorize(config.actor, value.caller)
        local result = require(name)(json.encode(call, NULL))
        return native(decode(result), NULL)
    end

    local function invoke(input, opaque)
        assert(
            type(input) == "string" and #input <= spec.limits.request_bytes and utf8.len(input),
            "invalid Zinc input"
        )
        local config = configuration(opaque)
        local value = object(input, { question = true, parent = true, memory = true })
        if value.parent == NULL then
            value.parent = nil
        end
        request(value, false)
        local _, final = runner:root({
            actor = config.actor,
            imports = config.imports,
            memory = value.memory,
            parent = value.parent,
            preset = spec.presets[config.preset],
            preset_name = config.preset,
            question = value.question,
            quota = config.quota == NULL and spec.quota or config.quota,
        })
        return json.encode({
            id = final.id,
            parent = final.parent or NULL,
            memory = final.memory,
            text = final.text,
        }, NULL)
    end

    runner = make_run(spec, entry, make_model(spec.model), documents)
    return setmetatable(entry, {
        __call = function(_, input, opaque)
            return invoke(input, opaque)
        end,
        __metatable = false,
    })
end
