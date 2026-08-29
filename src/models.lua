local json = require("lunajson")
local sse = require("src.sse")
local null = {}
local tool = {
    type = "function",
    ["function"] = {
        name = "run_lua",
        parameters = {
            type = "object",
            additionalProperties = false,
            required = { "code" },
            properties = { code = { type = "string" } },
        },
    },
}
local function next_value(iterator, ...)
    local value = iterator(...)
    while type(value) == "function" do
        value = iterator(coroutine.yield(value))
    end
    return value
end
local function collect(iterator)
    local chunks, response, event = {}, nil, next_value(iterator)
    while event do
        if event.type == "data" then
            chunks[#chunks + 1] = event.data
        else
            response = event
        end
        event = next_value(iterator)
    end
    return table.concat(chunks), response
end

return function(config, http)
    local chat, rerank = assert(config.models.chat), assert(config.models.rerank)
    local function request(model, accept, value)
        local body = json.encode(value, null)
        assert(#body <= config.max_model_request_bytes, "model request exceeds configured byte limit")
        return http({
            url = model.endpoint,
            method = "POST",
            body = body,
            headers = { ["content-type"] = "application/json", accept = accept },
        })
    end
    local api = {}

    function api:chat(messages)
        return coroutine.wrap(function()
            local parser = sse(config.host.limits.http_response_bytes)
            local calls, done, finish, response = {}, false
            local iterator = request(chat, "text/event-stream", {
                model = chat.model,
                messages = messages,
                tools = { tool },
                tool_choice = "auto",
                parallel_tool_calls = true,
                stream = true,
            })
            local event = next_value(iterator)
            while event do
                if event.type == "response" then
                    response = event
                else
                    for _, record in ipairs(parser:push(event.data)) do
                        if record.data == "[DONE]" then
                            done = true
                        else
                            local value = json.decode(record.data, 1, null)
                            assert(type(value) == "table" and type(value.error) ~= "table", "invalid chat event")
                            local choice = value.choices and value.choices[1]
                            if choice then
                                local delta = assert(choice.delta, "chat event has no delta")
                                local reasoning = delta.reasoning_content or delta.reasoning
                                if reasoning and reasoning ~= null and reasoning ~= "" then
                                    coroutine.yield({ type = "reasoning", text = reasoning })
                                end
                                if delta.content and delta.content ~= null and delta.content ~= "" then
                                    coroutine.yield({ type = "response", text = delta.content })
                                end
                                for _, item in ipairs(delta.tool_calls == null and {} or delta.tool_calls or {}) do
                                    local index = assert(math.tointeger(item.index), "chat tool index is invalid") + 1
                                    local call, fn = calls[index] or {}, item["function"] or {}
                                    calls[index] = call
                                    for field, fragment in pairs({
                                        id = item.id,
                                        name = fn.name,
                                        arguments = fn.arguments,
                                    }) do
                                        if fragment and fragment ~= null then
                                            call[field] = (call[field] or "") .. fragment
                                        end
                                    end
                                end
                                finish = choice.finish_reason ~= null and choice.finish_reason or finish
                            end
                        end
                    end
                end
                event = next_value(iterator)
            end
            for _, record in ipairs(parser:finish()) do
                assert(record.data == "[DONE]", "trailing chat event is invalid")
            end
            assert(
                response and response.status >= 200 and response.status < 300 and done and finish,
                "chat stream ended incompletely"
            )
            local decoded, wire = {}, {}
            for _, call in ipairs(calls) do
                local arguments = json.decode(call.arguments, 1, null)
                assert(call.name == "run_lua" and type(call.id) == "string", "invalid tool call")
                assert(type(arguments.code) == "string" and next(arguments, "code") == nil, "invalid tool arguments")
                decoded[#decoded + 1] = { id = call.id, code = arguments.code }
                wire[#wire + 1] =
                    { id = call.id, type = "function", ["function"] = { name = "run_lua", arguments = call.arguments } }
            end
            assert(
                #decoded <= config.max_parallel_tools and (#decoded > 0) == (finish == "tool_calls"),
                "parallel tool limit"
            )
            coroutine.yield({ type = "finish", reason = finish, calls = decoded, wire = wire })
        end)
    end

    function api:rerank(query, passages)
        if #passages == 0 then
            return {}, 0
        end
        local selected, body = {}, nil
        for _, passage in ipairs(passages) do
            selected[#selected + 1] = passage
            local candidate = { documents = selected, model = rerank.model, query = query, top_n = #selected }
            if #json.encode(candidate, null) > config.max_model_request_bytes then
                selected[#selected] = nil
                break
            end
            body = candidate
        end
        assert(body, "first reranker passage exceeds the request byte budget")
        local source, response = collect(request(rerank, "application/json", body))
        assert(response and response.status >= 200 and response.status < 300, "reranker endpoint failed")
        local value, result, seen = json.decode(source, 1, null), {}, {}
        assert(type(value.results) == "table" and #value.results == #selected, "reranker response has the wrong count")
        for _, item in ipairs(value.results) do
            local index = type(item) == "table" and math.tointeger(item.index)
            assert(
                index
                    and index >= 0
                    and index < #selected
                    and not seen[index]
                    and type(item.relevance_score) == "number",
                "reranker item is invalid"
            )
            seen[index], result[#result + 1] = true, { index = index + 1, score = item.relevance_score }
        end
        return result, #selected
    end
    return api
end
