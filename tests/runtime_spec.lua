package.preload["pa.env"] = function()
    return function(source, name) return load(source, name, "t", _G) end
end
package.preload["zinc.history"] = assert(loadfile("src/history.lua"))
package.preload["zinc.internal.run"] = assert(loadfile("src/internal/run.lua"))
package.preload["zinc.internal.model"] = assert(loadfile("src/internal/model.lua"))
package.preload["zinc.internal.memory"] = assert(loadfile("src/internal/memory.lua"))

local json = require("lunajson")
local function collect(iterator)
    local events = {}
    for event in iterator do
        events[#events + 1] = event
    end
    return events
end
local make_run = require("zinc.internal.run")
local function runner(model, memory, limits)
    local ask = make_run(model, memory)
    return function(request)
        local iterator = ask(request or "request", "actor", "instructions", limits)
        return collect(iterator)
    end
end

describe("sequential runtime", function()
    it("orders streamed completion and terminal events", function()
        local model = { encode = function(_, value) return tostring(value) end }
        function model:chat(_, emit)
            emit({ type = "reasoning", text = "because" })
            emit({ type = "response", text = "answer" })
            return { calls = {}, wire = {} }
        end

        local types = {}
        for _, event in ipairs(runner(model)()) do
            types[#types + 1] = event.type
        end
        assert.are.same({ "reasoning", "reasoning_complete", "response", "response_complete", "done" }, types)
    end)

    it("returns Lua usage errors and preserves call order", function()
        local turn = 0
        local model = { encode = function(_, value) return json.encode(value) end }
        function model:chat(_, emit)
            turn = turn + 1
            if turn == 1 then
                return {
                    calls = { { id = "one", code = "error('bad usage')" }, { id = "two", code = "return 'second'" } },
                    wire = { { id = "one" }, { id = "two" } },
                }
            end
            emit({ type = "response", text = "done" })
            return { calls = {}, wire = {} }
        end

        local results = {}
        for _, event in ipairs(runner(model)()) do
            if event.type == "tool_result" then results[#results + 1] = { event.call, event.ok, event.text } end
        end
        assert.is_false(results[1][2])
        assert.matches("bad usage", results[1][3])
        assert.are.same({ "two", true, "second" }, results[2])
    end)

    it("shares one model-call budget with nested asks", function()
        local id = 0
        local memory = {}
        function memory:begin(actor, request)
            id = id + 1
            return { id = id, actor = actor, text = request }
        end

        function memory:append(actor, start, role, text)
            id = id + 1
            return { id = id, actor = actor, start = start, role = role, text = text }
        end

        function memory:read() return nil end

        function memory:around() return nil end

        function memory:context() return "{}" end

        local calls = 0
        local model = { encode = function(_, value) return json.encode(value) end }
        function model:chat(_, emit)
            calls = calls + 1
            if calls == 1 then return { calls = { { id = "nested", code = "return require('zinc.history').ask('nested')" } }, wire = { { id = "nested" } } } end
            emit({ type = "response", text = "nested answer" })
            return { calls = {}, wire = {} }
        end

        local ok, problem = pcall(runner(model, memory, { maximum_model_calls = 2 }))
        assert.is_false(ok)
        assert.matches("model call budget exhausted", problem)
        assert.equals(2, calls)
    end)
end)

describe("model protocol", function()
    local config = {
        chat = { endpoint = "chat", template = "template", tokenize = "tokenize", model = "chat", context_tokens = 128 },
        rerank = { endpoint = "rerank", tokenize = "tokenize", model = "rerank", passage_tokens = 64 },
    }
    local function model(chat, tokenize)
        return require("zinc.internal.model")(config, function(input)
            local body = input.url == "template" and '{"prompt":"prompt"}' or
                input.url == "tokenize" and (tokenize or '{"tokens":[1]}') or chat
            return { status = 200, headers = {}, body = body }
        end)
    end
    it("rejects sparse tool indices", function()
        local body =
        'data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"id","function":{"name":"run_lua","arguments":"{\\"code\\":\\"return 1\\"}"}}]},"finish_reason":"tool_calls"}]}\n\ndata: [DONE]\n\n'
        assert.has_error(function()
            model(body):chat({}, function() end)
        end, "tool calls are sparse")
    end)
    it("rejects data after completion", function()
        local body = 'data: [DONE]\n\ndata: {"choices":[]}\n\n'
        assert.has_error(function()
            model(body):chat({}, function() end)
        end, "chat data follows completion")
    end)
    it("requires dense tokenizer arrays", function()
        assert.has_error(function() model("", '{"tokens":{"one":1}}'):tokens("text") end,
            "tokenizer tokens must be dense")
    end)
end)

describe("memory", function()
    it("isolates actors, finalizes failures, and applies optional record limits", function()
        local path = os.tmpname()
        os.remove(path)
        local model = {}
        function model:encode(value) return json.encode(value) end

        function model:tokens(value)
            local count = 0
            for _ in value:gmatch("%S+") do
                count = count + 1
            end
            return count
        end

        function model:rerank(_, passages)
            local result = {}
            for index in ipairs(passages) do
                result[index] = index
            end
            return result
        end

        local memory = require("zinc.internal.memory")({
            store = path,
            cygnet = "data/cygnet.db",
            retrieval = { semantic_language = "en", semantic_depth = 1, semantic_attention_cutoff = 0 },
        }, model)
        local first = memory:begin("one", "first request")
        local short = memory:append("one", first.id, "assistant", "éabcdef", 4)
        assert(utf8.len(short.text) and #short.text <= 4)
        assert.is_false(pcall(memory.append, memory, "one", first.id, "invalid", "bad"))
        local valid = memory:append("one", first.id, "tool", "still works")
        local current = memory:begin("one", "current request")
        assert.equals(valid.id, memory:read("one", current.id, valid.id).id)
        local other = memory:begin("two", "other request")
        assert.is_nil(memory:read("two", other.id, valid.id))
        assert.is_string(memory:context("one", current.id, "portable agent", {
            retrieval = {
                chronological_records = 1,
                chronological_tokens = 64,
                semantic_terms = 8,
                grounding_tokens = 16,
                exact_forms = 4,
                candidates = 4,
                semantic_tokens = 64,
            },
        }))
        os.remove(path)
    end)
end)
