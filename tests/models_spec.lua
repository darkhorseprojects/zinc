local json = require("lunajson")
local Models = require("src.models")

local config = {
    max_model_request_bytes = 4096,
    max_parallel_tools = 4,
    host = { limits = { http_response_bytes = 4096 } },
    models = {
        chat = { endpoint = "http://model/chat", model = "chat" },
        rerank = { endpoint = "http://model/rerank", model = "rerank" },
    },
}

local function request(options)
    local values
    if options.url:match("/chat$") then
        values = {
            {
                type = "data",
                data = "data: " .. json.encode({ choices = { { delta = { reasoning_content = "think" } } } }) .. "\n\n",
            },
            {
                type = "data",
                data = "data: " .. json.encode({ choices = { { delta = { content = "answer" } } } }) .. "\n\n",
            },
            {
                type = "data",
                data = "data: "
                    .. json.encode({
                        choices = {
                            {
                                delta = {
                                    tool_calls = {
                                        {
                                            index = 1,
                                            id = "b",
                                            ["function"] = { name = "run_lua", arguments = '{"code":"return 2"}' },
                                        },
                                        {
                                            index = 0,
                                            id = "a",
                                            ["function"] = { name = "run_lua", arguments = '{"code":"return 1"}' },
                                        },
                                    },
                                },
                                finish_reason = "tool_calls",
                            },
                        },
                    })
                    .. "\n\ndata: [DONE]\n\n",
            },
            { type = "response", status = 200, headers = {} },
        }
    else
        values = {
            {
                type = "data",
                data = json.encode({
                    results = { { index = 1, relevance_score = 0.9 }, { index = 0, relevance_score = 0.8 } },
                }),
            },
            { type = "response", status = 200, headers = {} },
        }
    end
    local index = 0
    return function()
        index = index + 1
        return values[index]
    end
end

describe("models", function()
    it("normalizes streamed reasoning, response, and parallel calls", function()
        local models = Models(config, request)
        local iterator = models:chat({ { role = "user", content = "hello" } })
        assert.same({ type = "reasoning", text = "think" }, iterator())
        assert.same({ type = "response", text = "answer" }, iterator())
        local finish = iterator()
        assert.equals("finish", finish.type)
        assert.equals("tool_calls", finish.reason)
        assert.same({ "a", "b" }, { finish.calls[1].id, finish.calls[2].id })
        assert.is_nil(iterator())
    end)

    it("reranks one bounded candidate prefix", function()
        local models = Models(config, request)
        local ranking, count = models:rerank("query", { "first", "second" })
        assert.equals(2, count)
        assert.same({ { index = 2, score = 0.9 }, { index = 1, score = 0.8 } }, ranking)
    end)

    it("rejects tiny requests", function()
        local tiny = {
            max_model_request_bytes = 1,
            max_parallel_tools = 4,
            host = config.host,
            models = config.models,
        }
        local models = Models(tiny, request)
        assert.has_error(function()
            models:chat({ { role = "user", content = "x" } })()
        end)
    end)
end)
