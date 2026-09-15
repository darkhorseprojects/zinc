local json = require("lunajson")

local CONFIG = {
    origin = "http://model",
    chat = {
        endpoint = "/chat",
        template = "/template",
        tokenize = "/tokenize",
        model = "chat",
        context_tokens = 128,
        maximum_output_tokens = 16,
        maximum_tool_calls = 4,
        maximum_tool_source_bytes = 1024,
        maximum_event_bytes = 4096,
        maximum_response_bytes = 16384,
        maximum_item_bytes = 4096,
        maximum_events = 128,
        maximum_tool_argument_bytes = 4096,
    },
    rerank = { endpoint = "/rerank", tokenize = "/tokenize", model = "rerank", passage_tokens = 64 },
}

local function stream(events)
    local output = {}
    for _, event in ipairs(events) do
        output[#output + 1] = "data: " .. (event == "[DONE]" and event or json.encode(event)) .. "\n\n"
    end
    return table.concat(output)
end

local function model(events, inspect, rerank_response)
    package.loaded.pa = nil
    package.loaded["src.model"] = nil
    package.preload.pa = function()
        return {
            http = function(origin, method, path, body, headers)
                assert.equals(CONFIG.origin, origin)
                assert.equals("POST", method)
                assert.equals("application/json", headers["content-type"])
                if path == "/template" then
                    local request = json.decode(body)
                    if inspect then
                        inspect(request)
                    end
                    return 200, '{"prompt":"prompt"}'
                end
                if path == "/tokenize" then
                    local request, tokens = json.decode(body), { 1 }
                    if request.content:find("oversize", 1, true) then
                        for index = 2, 65 do
                            tokens[index] = index
                        end
                    end
                    return 200, json.encode({ tokens = tokens })
                end
                if path == "/rerank" then
                    return 200, rerank_response or '{"results":[{"index":0,"relevance_score":1}]}'
                end
                return 200, stream(events)
            end,
        }
    end
    return assert(loadfile("package/src/model.lua"))()(CONFIG)
end

describe("model protocol", function()
    after_each(function()
        package.loaded.pa = nil
        package.preload.pa = nil
    end)

    it("uses stateless PA HTTP and enables parallel tools", function()
        local checked = false
        local value = model({
            { choices = { { delta = { reasoning_content = "because" }, finish_reason = json.null } } },
            { choices = { { delta = { content = "answer" }, finish_reason = "stop" } } },
            "[DONE]",
        }, function(request)
            checked = request.parallel_tool_calls == true
        end):chat({})
        assert.is_true(checked)
        assert.equals("reasoning", value.items[1].type)
        assert.equals("response", value.items[2].type)
        assert.equals("response", value.last)
    end)

    it("keeps tool calls in model index order", function()
        local arguments = function(code)
            return json.encode({ code = code })
        end
        local value = model({
            {
                choices = {
                    {
                        delta = {
                            tool_calls = {
                                {
                                    index = 0,
                                    id = "z",
                                    ["function"] = { name = "run_lua", arguments = arguments("return 'first'") },
                                },
                                {
                                    index = 1,
                                    id = "a",
                                    ["function"] = { name = "run_lua", arguments = arguments("return 'second'") },
                                },
                            },
                        },
                        finish_reason = "tool_calls",
                    },
                },
            },
            "[DONE]",
        }):chat({})
        assert.equals("tool", value.last)
        assert.equals("z", value.items[1].calls[1].id)
        assert.equals("a", value.items[1].calls[2].id)
    end)

    it("skips oversized reranker passages without losing source indices", function()
        assert.same({ 2 }, model({}):rerank("query", { string.rep("oversize", 9), "fits" }))
    end)

    it("rejects non-finite reranker scores", function()
        assert.has_error(function()
            model({}, nil, '{"results":[{"index":0,"relevance_score":1e999}]}'):rerank("query", { "fits" })
        end, "reranker score is invalid")
    end)

    it("continues when reasoning is the last item", function()
        local value = model({
            { choices = { { delta = { content = "not terminal yet" }, finish_reason = json.null } } },
            { choices = { { delta = { reasoning_content = "continue" }, finish_reason = "stop" } } },
            "[DONE]",
        }):chat({})
        assert.equals("reasoning", value.last)
    end)

    it("rejects sparse tool indices", function()
        local arguments = json.encode({ code = "return 'x'" })
        assert.has_error(function()
            model({
                {
                    choices = {
                        {
                            delta = {
                                tool_calls = {
                                    {
                                        index = 1,
                                        id = "id",
                                        ["function"] = { name = "run_lua", arguments = arguments },
                                    },
                                },
                            },
                            finish_reason = "tool_calls",
                        },
                    },
                },
                "[DONE]",
            }):chat({})
        end, "tool calls are sparse")
    end)
end)
