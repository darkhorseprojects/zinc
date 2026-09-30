local decode_json = require("lunajson.decoder")()
local encode_json = require("lunajson.encoder")()
local make_model = require("src.model")
local make_run = require("src.run")

local NULL = {}

local function decode(source, maximum)
    assert(type(source) == "string" and (not maximum or #source <= maximum) and utf8.len(source), "invalid JSON bytes")
    local value, offset = decode_json(source, 1, NULL)
    assert(source:sub(offset):match("^%s*$"), "JSON has trailing data")
    return value
end

local function object(source, fields, maximum)
    assert(source:match("^%s*{"), "JSON value must be an object")
    local value = decode(source, maximum)
    assert(type(value) == "table", "JSON value must be an object")
    for key in pairs(value) do
        assert(fields[key], "unknown JSON field: " .. tostring(key))
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
    local fields = { text = true, parent = true, through = true, images = not nested, preset = nested }
    for key in pairs(value) do
        assert(fields[key], "unknown Zinc request field: " .. tostring(key))
    end
    assert(type(value.text) == "string" and value.text ~= "" and utf8.len(value.text), "invalid text")
    assert(value.parent == nil or math.type(value.parent) == "integer" and value.parent >= 0, "invalid parent")
    assert(value.through == nil or math.type(value.through) == "integer" and value.through >= 0, "invalid through")
    assert(not nested or value.through ~= nil, "nested calls require parent and through")
    assert(not nested or value.preset == nil or type(value.preset) == "string", "invalid preset")
    value.question, value.memory, value.automatic = value.text, value.through, value.parent == nil
    if value.parent == 0 then
        value.parent = nil
    end
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
            if field == "config.search.score" then
                assert(
                    type(selected) == "number" and selected == selected and math.abs(selected) < math.huge,
                    "invalid " .. field
                )
            else
                assert(math.type(selected) == "integer" and selected >= 0 and selected <= value, "invalid " .. field)
                if not path:find("^config%.history") and not path:find("^config%.search") then
                    assert(selected > 0, "invalid " .. field)
                end
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
        assert(defaults[name] ~= nil, "unknown " .. path .. " field: " .. tostring(name))
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
        local fields = { actor = true, preset = true, store = true, cygnet = true, providers = true, tools = true }
        for name in pairs(spec.defaults) do
            fields[name] = true
        end
        local value = object(source, fields, spec.limits.config_bytes)
        assert(type(value.actor) == "string" and value.actor ~= "" and utf8.len(value.actor), "invalid actor")
        assert(spec.presets[value.preset], "unknown Zinc preset")
        assert(type(value.store) == "string" and value.store ~= "", "store path is required")
        assert(type(value.cygnet) == "string" and value.cygnet ~= "", "Cygnet path is required")
        assert(
            type(value.providers) == "table" and value.providers ~= NULL and next(value.providers),
            "providers are required"
        )
        for name, provider in pairs(value.providers) do
            assert(name == "llama" or name == "openrouter", "unsupported model provider: " .. tostring(name))
            assert(type(provider) == "table" and type(provider.url) == "string", "invalid provider: " .. name)
            assert(provider.url:match("^https?://[^/%s?#]+$"), "provider URL must be an HTTP origin")
            assert(
                provider.token == nil or type(provider.token) == "string" and provider.token ~= "",
                "invalid provider token"
            )
            for key in pairs(provider) do
                assert(key == "url" or key == "token", "unknown provider field: " .. tostring(key))
            end
        end
        local overrides = {}
        for name in pairs(spec.defaults) do
            overrides[name] = value[name]
        end
        local selected = merge(spec.defaults, overrides, "config")
        assert(selected.limits.rerank.pair_bytes > selected.limits.rerank.query_bytes, "invalid rerank limits")
        assert(selected.run.tool_bytes >= 128, "tool result limit must be at least 128 bytes")
        for name, item in pairs(selected) do
            value[name] = item
        end
        local tools = value.tools or {}
        assert(type(tools) == "table" and tools ~= NULL, "invalid tools")
        for key in pairs(tools) do
            assert(key == "roots" or key == "actions" or key == "search", "unknown tools field: " .. tostring(key))
        end
        tools.roots, tools.actions = tools.roots or {}, tools.actions or {}
        assert(type(tools.roots) == "table" and type(tools.actions) == "table", "invalid tool grants")
        for name, path in pairs(tools.roots) do
            assert(type(name) == "string" and type(path) == "string" and path ~= "", "invalid tool root")
        end
        for name, action in pairs(tools.actions) do
            assert(type(name) == "string" and type(action) == "table", "invalid HTTP action")
            for key in pairs(action) do
                assert(key == "method" or key == "origin" or key == "path", "unknown HTTP action field")
            end
            assert(
                type(action.method) == "string" and type(action.origin) == "string" and type(action.path) == "string",
                "invalid HTTP action"
            )
        end
        assert(
            tools.search == nil or type(tools.search) == "string" and tools.search ~= "",
            "invalid search executable"
        )
        value.tools = tools
        return value
    end

    local entry, runner = {}, nil

    function entry.describe(input, opaque)
        assert(input == "", "describe takes empty input")
        local value = decode(opaque, spec.limits.config_bytes)
        local overrides = {}
        for name in pairs(spec.defaults) do
            overrides[name] = value[name]
        end
        local config = merge(spec.defaults, overrides, "config")
        local parameters = {
            {
                name = "model",
                path = "config.model",
                type = "string",
                description = "Chat model",
                autocomplete = "chat",
            },
            {
                name = "rerank",
                path = "config.rerank",
                type = "string",
                description = "Rerank model",
                autocomplete = "rerank",
            },
            { name = "thinking", path = "config.thinking", type = "boolean", description = "Enable model thinking" },
            {
                name = "parent",
                path = "input.parent",
                type = "integer",
                description = "Parent event; zero starts a fresh branch",
                minimum = 0,
            },
            {
                name = "through",
                path = "input.through",
                type = "integer",
                description = "Inclusive history event; zero disables history",
                minimum = 0,
            },
        }
        for _, field in ipairs({
            { "tokens", "run", "tokens", "Run token quota", 1 },
            { "rounds", "run", "rounds", "Maximum model rounds", 1 },
            { "tool_bytes", "run", "tool_bytes", "Tool result byte limit", 128 },
            { "history_records", "history", "records", "Recent history records", 0 },
            { "history_bytes", "history", "bytes", "Recent history byte limit", 0 },
            { "candidates", "search", "candidates", "Search candidates", 0 },
            { "search_bytes", "search", "bytes", "Retrieved history byte limit", 0 },
            { "depth", "search", "depth", "Relation expansion depth", 0 },
            { "terms", "search", "terms", "Search term limit", 0 },
        }) do
            parameters[#parameters + 1] = {
                name = field[1],
                path = "config." .. field[2] .. "." .. field[3],
                type = "integer",
                description = field[4],
                minimum = field[5],
                maximum = config[field[2]][field[3]],
            }
        end
        parameters[#parameters + 1] =
            { name = "score", path = "config.search.score", type = "number", description = "Minimum rerank score" }
        return encode_json({ input = "json", output = "json", parameters = parameters })
    end

    function entry.models(input, opaque)
        assert(input == "chat" or input == "rerank", "models takes chat or rerank")
        return encode_json(make_model(configuration(opaque)):models(input))
    end

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
            return descriptor.call(value.action, value.arguments, config.tools)
        end
    end

    function entry.zinc_call(value, opaque)
        local config = configuration(opaque)
        assert(type(value) == "table" and math.type(value.caller) == "integer", "invalid Zinc caller")
        local call, final = runner:nested(config, value.caller, request(value.arguments[1], true))
        return {
            branch = call.branch,
            event = final.id,
            parent = final.parent,
            through = final.memory,
            text = final.text,
        }
    end

    function entry.zinc_destroy(value, opaque)
        local config = configuration(opaque)
        assert(type(value) == "table" and math.type(value.caller) == "integer", "invalid Zinc caller")
        local branch = value.arguments and value.arguments[1]
        assert(math.type(branch) == "integer" and branch > 0, "invalid branch")
        return runner:destroy(config, value.caller, branch)
    end

    local function invoke(input, opaque)
        local value = request(
            object(input, { text = true, images = true, parent = true, through = true }, spec.limits.request_bytes),
            false
        )
        assert(#value.text <= spec.limits.question_bytes, "Zinc text is too large")
        if value.images then
            assert(type(value.images) == "table" and value.images ~= NULL and #value.images <= 4, "invalid image count")
            for key, image in pairs(value.images) do
                assert(math.type(key) == "integer" and key >= 1 and key <= #value.images, "invalid image array")
                assert(
                    type(image) == "table"
                        and (image.type == "image/png" or image.type == "image/jpeg" or image.type == "image/webp"),
                    "invalid image type"
                )
                assert(type(image.data) == "string" and image.data:match("^[A-Za-z0-9+/]+=?=?$"), "invalid image data")
                for name in pairs(image) do
                    assert(name == "type" or name == "data", "unknown image field")
                end
            end
            if #value.images == 0 then
                value.images = nil
            end
        end
        local config = configuration(opaque)
        local call, final, usage = runner:root({
            actor = config.actor,
            automatic = value.automatic,
            config = config,
            memory = value.memory,
            parent = value.parent,
            preset = spec.presets[config.preset],
            preset_name = config.preset,
            question = value.question,
            images = value.images,
            quota = config.run.tokens,
        })
        return encode_json({
            text = final.text,
            run = call.run,
            branch = call.branch,
            event = final.id,
            parent = final.parent or 0,
            through = final.memory,
            usage = { total_tokens = usage },
        })
    end

    runner = make_run(spec, entry, make_model, documents)
    return setmetatable(entry, {
        __call = function(_, input, opaque)
            return invoke(input, opaque)
        end,
        __metatable = false,
    })
end
