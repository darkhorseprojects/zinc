package.preload["pa.env"] = function()
    return function(source, name) return load(source, name, "t", _G) end
end
package.preload["zinc.history"] = assert(loadfile("src/history.lua"))
package.preload["zinc.internal.run"] = assert(loadfile("src/internal/run.lua"))

local function collect(iterator)
    local events = {}
    for event in iterator do events[#events + 1] = event end
    return events
end

local make_run = require("zinc.internal.run")
local function runner(model)
    local ask = make_run({ maximum_turns = 3, maximum_nested_requests = 2 }, model, nil)
    return function()
        local iterator = ask("request", "actor", "instructions")
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
        local events = runner(model)()
        local types = {}
        for _, event in ipairs(events) do types[#types + 1] = event.type end
        assert.are.same({ "reasoning", "reasoning_complete", "response", "response_complete", "done" }, types)
    end)

    it("executes tool calls in model order", function()
        local turn = 0
        local model = { encode = function(_, value) return tostring(value) end }
        function model:chat(_, emit)
            turn = turn + 1
            if turn == 1 then
                return {
                    calls = { { id = "one", code = "return 'first'" }, { id = "two", code = "return 'second'" } },
                    wire = { { id = "one" }, { id = "two" } },
                }
            end
            emit({ type = "response", text = "done" })
            return { calls = {}, wire = {} }
        end
        local calls = {}
        for _, event in ipairs(runner(model)()) do
            if event.type == "tool_result" then calls[#calls + 1] = { event.call, event.text, event.ok } end
        end
        assert.are.same({ { "one", "first", true }, { "two", "second", true } }, calls)
    end)
end)
