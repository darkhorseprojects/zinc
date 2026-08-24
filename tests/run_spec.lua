local json = require("dkjson")
local Run = require("src.run")

local function encode(value)
    return assert(json.encode(value))
end
local function decode(value)
    return assert(json.decode(value))
end

local function execute(agent, request, actor)
    local thread = coroutine.create(function()
        agent.ask(request, actor)
    end)
    local events = {}
    while coroutine.status(thread) ~= "dead" do
        local ok, value = coroutine.resume(thread)
        assert.is_true(ok, value)
        if coroutine.status(thread) ~= "dead" then
            events[#events + 1] = decode(value)
        end
    end
    return events
end

describe("run_lua", function()
    it("exposes only guided capabilities and invocation-local results", function()
        local id, records = 0, {}
        local store = {}
        function store:begin(actor, text)
            id = id + 1
            local row = { id = id, actor = actor, start = id, role = "user", text = text }
            records[#records + 1] = row
            return row
        end
        function store:append(actor, start, role, text)
            id = id + 1
            local row = { id = id, actor = actor, start = start, role = role, text = text }
            records[#records + 1] = row
            return row
        end
        function store:read(actor, start, result)
            return { actor = actor, start = start, id = result, text = "history" }
        end
        function store:around()
            return nil
        end
        local retrieval = {}
        function retrieval:start()
            return {}
        end
        function retrieval:context()
            return "{}"
        end
        local rounds = 0
        local models = { encode = encode, decode = decode, null = json.null }
        function models:chat()
            rounds = rounds + 1
            local values
            if rounds == 1 then
                local code = [[
local loaded={};for name in pairs(package.loaded)do loaded[#loaded+1]=name end;table.sort(loaded)
return {host=require('host').value,results=type(require('results').read),loaded=loaded,
 source=pcall(require,'src.run'),system=pcall(require,'dkjson'),missing=pcall(require,'missing')}
]]
                values = {
                    { type = "tool" },
                    {
                        type = "finish",
                        reason = "tool_calls",
                        tool_calls = { { id = "x", name = "run_lua", arguments = encode({ code = code }) } },
                    },
                }
            else
                values = { { type = "response", text = "done" }, { type = "finish", reason = "stop", tool_calls = {} } }
            end
            local index = 0
            return function()
                index = index + 1
                return values[index]
            end
        end
        local agent = Run.new({
            name = "zinc",
            instructions = "test",
            capabilities = { host = { guide = "guide", value = "available" } },
            store = store,
            retrieval = retrieval,
            models = models,
        })
        local events = execute(agent, "request", "actor")
        local result = decode(events[2].text)
        assert.equals("available", result.host)
        assert.equals("function", result.results)
        assert.same({ "host", "results" }, result.loaded)
        assert.is_false(result.source)
        assert.is_false(result.system)
        assert.is_false(result.missing)
        assert.equals("store", events[#events].type)
        assert.equals(4, #records)
    end)
end)
