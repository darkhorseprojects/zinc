local json = require("lunajson")
local Models = require("src.models")

local config = {
    max_model_context_tokens = 64,
    min_model_output_tokens = 8,
    max_rerank_passage_tokens = 100,
    max_parallel_tools = 4,
    host = { limits = { http_response_bytes = 4096 } },
    models = {
        chat = {
            endpoint = "http://model/chat",
            template = "http://model/template",
            tokenize = "http://model/tokenize",
            model = "chat",
        },
        rerank = {
            endpoint = "http://model/rerank",
            tokenize = "http://model/tokenize",
            model = "rerank",
        },
    },
}

local function iterator(values)
    local index = 0
    return function()
        index = index + 1
        return values[index]
    end
end

local function fixture()
    local seen = {}
    local function response(value)
        return iterator({
            { type = "data", data = json.encode(value) },
            { type = "response", status = 200, headers = {} },
        })
    end
    local function request(options)
        local body = json.decode(options.body)
        seen[#seen + 1] = { url = options.url, body = body }
        if options.url:match("/template$") then
            return response({ prompt = "prompt" })
        elseif options.url:match("/tokenize$") then
            local tokens = {}
            for index = 1, #body.content do
                tokens[index] = index
            end
            return response({ tokens = tokens })
        elseif options.url:match("/chat$") then
            return iterator({
                {
                    type = "data",
                    data = "data: "
                        .. json.encode({ choices = { { delta = { reasoning_content = "think" } } } })
                        .. "\n\n",
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
            })
        end
        return response({
            results = { { index = 1, relevance_score = 0.9 }, { index = 0, relevance_score = 0.8 } },
        })
    end
    return request, seen
end

describe("models", function()
    it("counts the rendered prompt and uses all remaining output context", function()
        local request, seen = fixture()
        local stream = Models(config, request):chat({ { role = "user", content = "hello" } })
        assert.same({ type = "reasoning", text = "think" }, stream())
        assert.same({ type = "response", text = "answer" }, stream())
        local finish = stream()
        assert.equals("tool_calls", finish.reason)
        assert.same({ "a", "b" }, { finish.calls[1].id, finish.calls[2].id })
        assert.equals(58, seen[3].body.max_tokens)
        assert.is_nil(stream())
    end)

    it("reranks one token-bounded candidate prefix", function()
        local request = fixture()
        local ranking, count = Models(config, request):rerank("query", { "first", "second" })
        assert.equals(2, count)
        assert.same({ { index = 2, score = 0.9 }, { index = 1, score = 0.8 } }, ranking)
    end)

    it("requires the minimum output reserve", function()
        local tiny = {}
        for key, value in pairs(config) do
            tiny[key] = value
        end
        tiny.max_model_context_tokens = 10
        tiny.min_model_output_tokens = 5
        local request = fixture()
        local models = Models(tiny, request)
        assert.has_error(function()
            models:chat({ { role = "user", content = "x" } })()
        end)
    end)
end)
