local json = require("lunajson")
local pa = require("pa")

local NULL = {}

local function decode(source)
    local value, offset = json.decode(source, 1, NULL)
    assert(source:sub(offset):match("^%s*$"), "JSON has trailing data")
    return value
end

local TOOL = {
    type = "function",
    ["function"] = {
        name = "run_lua",
        description = "Evaluate Lua source.",
        parameters = {
            type = "object",
            additionalProperties = false,
            required = { "code" },
            properties = {
                code = { type = "string", description = "Source." },
            },
        },
    },
}

local function dense(value, name)
    assert(type(value) == "table", name .. " must be an array")
    local size = #value
    for key in pairs(value) do
        assert(math.type(key) == "integer" and key >= 1 and key <= size, name .. " must be dense")
    end
    return value
end

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

return function(origin, config)
    local chat, rerank = config.chat, config.rerank

    local function request(path, value, maximum)
        local status, body = pa.http(origin, "POST", path, json.encode(value, NULL), {
            ["content-type"] = "application/json",
            accept = "application/json",
        })
        assert(status >= 200 and status < 300, "model endpoint failed")
        assert(not maximum or #body <= maximum, "model response is too large")
        local result = decode(body)
        assert(type(result) == "table" and type(result.error) ~= "table", "invalid model response")
        return result
    end

    local function post(model, path, value, maximum)
        value.model = model.name
        return request(path, value, maximum)
    end

    local function tokens(model, content)
        local result = post(model, "/tokenize", {
            content = content,
            add_special = false,
            parse_special = false,
        })
        return #dense(result.tokens, "tokenizer tokens")
    end

    local api = {}

    function api:tokens(content)
        return tokens(chat, content)
    end

    function api:chat(messages)
        local result = post(chat, "/v1/chat/completions", {
            messages = messages,
            tools = { TOOL },
            parallel_tool_calls = true,
            max_tokens = chat.maximum_output_tokens,
            chat_template_kwargs = { enable_thinking = chat.thinking },
            stream = false,
        }, chat.maximum_response_bytes)
        local choices = dense(result.choices, "chat choices")
        assert(#choices == 1, "chat response has the wrong choice count")
        local choice = choices[1]
        local message = assert(type(choice) == "table" and choice.message, "chat response has no message")
        local reasoning = message.reasoning_content or message.reasoning
        local content = message.content
        if reasoning == NULL then
            reasoning = nil
        end
        if content == NULL then
            content = nil
        end
        assert(reasoning == nil or type(reasoning) == "string" and utf8.len(reasoning), "invalid reasoning")
        assert(content == nil or type(content) == "string" and utf8.len(content), "invalid response")

        local entries = message.tool_calls == NULL and {} or dense(message.tool_calls or {}, "chat tool calls")
        assert(#entries <= chat.maximum_tool_calls, "tool call limit")
        local calls, tool_calls, ids = {}, {}, {}
        for index, entry in ipairs(entries) do
            local fn = type(entry) == "table" and entry["function"]
            local id = type(entry) == "table" and entry.id
            local name = type(fn) == "table" and fn.name
            local arguments = type(fn) == "table" and fn.arguments
            assert(type(id) == "string" and id ~= "" and utf8.len(id) and not ids[id], "invalid tool call")
            assert(name == "run_lua" and type(arguments) == "string", "invalid tool call")
            assert(#arguments <= chat.maximum_tool_argument_bytes, "tool arguments are too large")
            local decoded = decode(arguments)
            assert(type(decoded) == "table", "invalid tool arguments")
            for key in pairs(decoded) do
                assert(key == "code", "unknown tool argument")
            end
            assert(
                type(decoded.code) == "string"
                    and decoded.code ~= ""
                    and utf8.len(decoded.code)
                    and #decoded.code <= chat.maximum_tool_source_bytes,
                "invalid tool source"
            )
            ids[id] = true
            calls[index] = { id = id, code = decoded.code }
            tool_calls[index] = { id = id, type = "function", ["function"] = { name = name, arguments = arguments } }
        end

        assert(choice.finish_reason ~= "length", "chat completion was truncated")
        if #calls == 0 then
            assert(choice.finish_reason == "stop" and content and content ~= "", "chat completion has no response")
        else
            assert(choice.finish_reason == "tool_calls" or choice.finish_reason == "stop", "invalid tool completion")
        end
        return { reasoning = reasoning, content = content, calls = calls, tool_calls = tool_calls }
    end

    function api:rerank(query, passages)
        if #query > rerank.query_tokens and tokens(rerank, query) > rerank.query_tokens then
            return {}
        end
        local selected, source = {}, {}
        for index, passage in ipairs(passages) do
            local content = query .. "\n" .. passage
            if #content <= rerank.passage_tokens or tokens(rerank, content) <= rerank.passage_tokens then
                selected[#selected + 1], source[#source + 1] = passage, index
            end
        end
        if #selected == 0 then
            return {}
        end
        local ranked = post(rerank, "/v1/rerank", {
            documents = selected,
            query = query,
            top_n = #selected,
        }).results
        dense(ranked, "reranker results")
        assert(#ranked == #selected, "reranker response has the wrong count")
        local output, seen = {}, {}
        for _, entry in ipairs(ranked) do
            local index = type(entry) == "table" and math.tointeger(entry.index)
            assert(index and index >= 0 and index < #selected and not seen[index], "reranker index is invalid")
            assert(finite(entry.relevance_score), "reranker score is invalid")
            seen[index], output[#output + 1] = true, source[index + 1]
        end
        return output
    end

    return api
end
