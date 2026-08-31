package.preload["pa.env"] = function() return assert(loadfile("../portable-agents/src/pa/env.lua"))() end
local Run = require("zinc.internal.run")

local function store()
    local api = { records = {}, next = 0 }
    local function record(self, actor, start, role, text)
        self.next = self.next + 1
        local value = { id = self.next, actor = actor, start = start or self.next, role = role, text = text }
        self.records[#self.records + 1] = value
        return value
    end
    function api:begin(actor, text) return record(self, actor, nil, "user", text) end
    function api:append(actor, start, role, text) return record(self, actor, start, role, text) end
    function api:read() return nil end
    function api:around() return nil end
    return api
end

local function models()
    local api = {}
    function api:chat(messages, emit)
        self.messages = messages
        emit({ type = "reasoning", text = "thinking" })
        emit({ type = "response", text = "answer" })
        return { type = "finish", reason = "stop", calls = {}, wire = {} }
    end
    return api
end

describe("run", function()
    it("commits every durable completion before Store", function()
        local database, model = store(), models()
        local function retrieval() return "{}" end
        local ask = Run(model, database, retrieval)
        local output, stream = {}, ask("request", "actor", "instructions")
        for event in stream do
            output[#output + 1] = event
        end
        assert.same({ "reasoning", "reasoning_complete", "response", "response_complete", "store" }, {
            output[1].type,
            output[2].type,
            output[3].type,
            output[4].type,
            output[5].type,
        })
        assert.same({ 1, 2, 3 }, { database.records[1].id, output[2].result, output[4].result })
        assert.equals(3, output[5].result)
        assert.equals(1, output[5].start)
    end)

    it("rejects nil generated returns", function()
        local database = store()
        local model = { count = 0 }
        function model:chat(_, emit)
            self.count = self.count + 1
            if self.count == 1 then
                return {
                    type = "finish",
                    reason = "tool_calls",
                    calls = { { id = "call", code = "return nil" } },
                    wire = {
                        {
                            id = "call",
                            type = "function",
                            ["function"] = { name = "run_lua", arguments = '{"code":"return nil"}' },
                        },
                    },
                }
            end
            emit({ type = "response", text = "corrected" })
            return { type = "finish", reason = "stop", calls = {}, wire = {} }
        end
        local function retrieval() return "{}" end
        local stream = Run(model, database, retrieval)("request", "actor", "instructions")
        local tool_result
        for event in stream do
            if event.type == "tool_result" then tool_result = event end
        end
        assert.is_false(tool_result.ok)
        assert.equals("run_lua returned nil", tool_result.text)
    end)
end)
