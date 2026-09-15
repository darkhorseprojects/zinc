local json = require("lunajson")

local function build()
    package.loaded["src.model"] = nil
    package.loaded["src.run"] = nil
    package.preload["src.model"] = function()
        return function()
            return "model"
        end
    end
    local captured
    package.preload["src.run"] = function()
        return function()
            return function(call)
                captured = call
                return { id = 7, parent = nil, memory = call.memory, text = "answer" }
            end
        end
    end
    local safe_call = function(input)
        return "safe:" .. input
    end
    local unsafe_call = function(input)
        return "unsafe:" .. input
    end
    local spec = {
        document = { Zinc = { "instructions" } },
        design = { Design = { "design" } },
        model = { chat = { context_tokens = 128, maximum_output_tokens = 16, maximum_tool_source_bytes = 64 } },
        store = {},
        memory = {
            cygnet = "cygnet.db",
            semantic_language = "en",
            semantic_depth = 1,
            semantic_attention_cutoff = 0,
            chronological_records = 8,
            chronological_tokens = 128,
            semantic_terms = 16,
            grounding_tokens = 16,
            exact_forms = 4,
            candidates = 8,
            semantic_tokens = 128,
        },
        limits = {
            config_bytes = 4096,
            request_bytes = 4096,
            record_bytes = 4096,
            tool_result_bytes = 4096,
            model_rounds = 8,
        },
        presets = {
            safe = { document = {}, members = { fetch = { call = safe_call, prompt = "fetch" } } },
            unsafe = { document = {}, members = { process = { call = unsafe_call, prompt = "process" } } },
            ["no-host"] = { document = {}, members = {} },
        },
    }
    local entry = assert(loadfile("package/src/entry.lua"))()(spec)
    return entry, function()
        return captured
    end
end

local function config(preset)
    return json.encode({ version = 1, actor = "actor", preset = preset, imports = {} })
end

describe("Zinc entry", function()
    after_each(function()
        for _, name in ipairs({ "src.model", "src.run" }) do
            package.loaded[name] = nil
            package.preload[name] = nil
        end
    end)

    it("builds the core and trusted preset-member union", function()
        local entry = build()
        local names = {}
        for name in pairs(entry) do
            names[#names + 1] = name
        end
        table.sort(names)
        assert.same({ "design", "document", "fetch", "process", "zinc" }, names)
        assert.equals("safe:x", entry.fetch("x", config("safe")))
        assert.equals("unsafe:x", entry.process("x", config("unsafe")))
        assert.has_error(function()
            entry.fetch("x", config("no-host"))
        end, "fetch is unavailable")
    end)

    it("passes only typed trusted identity and request fields to execution", function()
        local entry, captured = build()
        local null = {}
        local result =
            json.decode(entry(json.encode({ question = "question", parent = null, memory = 0 }, null), config("safe")))
        assert.equals("answer", result.text)
        assert.is_nil(result.parent)
        assert.equals("actor", captured().actor)
        assert.equals("question", captured().question)
        assert.equals(0, captured().memory)
    end)

    it("rejects authority in input and unknown config fields", function()
        local entry = build()
        assert.has_error(function()
            entry('{"question":"x","parent":null,"memory":0,"actor":"other"}', config("safe"))
        end, "unknown JSON field")
        assert.has_error(function()
            entry(
                '{"question":"x","parent":null,"memory":0}',
                '{"version":1,"actor":"a","preset":"safe","imports":{},"extra":true}'
            )
        end, "unknown JSON field")
    end)
end)
