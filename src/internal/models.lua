local json = require("lunajson")
local sse = require("zinc.internal.sse")
local next_value = require("zinc.internal.stream")
local null = {}
local tool = {
    type = "function",
    ["function"] = {
        name = "run_lua",
        description = "Execute a Lua chunk that returns one non-nil value.",
        parameters = { type = "object", required = { "code" }, properties = { code = { type = "string" } } },
    },
}

local function collect(iterator)
    local chunks, event = {}, next_value(iterator)
    while event and event.type == "data" do
        chunks[#chunks + 1] = event.data
        event = next_value(iterator)
    end
    return table.concat(chunks), event
end

return function(config, http)
    local chat, rerank = assert(config.chat), assert(config.rerank)
    local context = assert(math.tointeger(chat.context_tokens), "model context must be an integer")
    local reserve = assert(math.tointeger(chat.minimum_output_tokens), "model output reserve must be an integer")
    assert(context > reserve and reserve > 0, "model token limits are invalid")

    local function request(endpoint, accept, value)
        return http({
            url = endpoint,
            method = "POST",
            body = json.encode(value, null),
            headers = { ["content-type"] = "application/json", accept = accept },
        })
    end

    local function post(model, endpoint, value)
        value.model = model.model
        local source, response = collect(request(endpoint, "application/json", value))
        assert(response and response.status >= 200 and response.status < 300, "model endpoint failed")
        local decoded = json.decode(source, 1, null)
        assert(type(decoded) == "table" and type(decoded.error) ~= "table", "invalid model response")
        return decoded
    end

    local function tokens(model, content, parse_special)
        local value = post(model, assert(model.tokenize), {
            content = content,
            add_special = false,
            parse_special = parse_special or false,
        })
        assert(type(value.tokens) == "table", "tokenizer response has no tokens")
        return #value.tokens
    end

    local api = {}
    function api:encode(value)
        return json.encode(value, null)
    end
    function api:tokens(content)
        return tokens(chat, content)
    end

    function api:chat(messages)
        return coroutine.wrap(function()
            local value = {
                messages = messages,
                tools = { tool },
                tool_choice = "auto",
                parallel_tool_calls = true,
                add_generation_prompt = true,
            }
            local template = post(chat, assert(chat.template), value)
            value.add_generation_prompt, value.stream = nil, true
            assert(type(template.prompt) == "string", "template response has no prompt")
            local used = tokens(chat, template.prompt, true)
            assert(used + reserve <= context, "model prompt leaves too few output tokens")
            value.max_tokens = context - used

            local parser = sse()
            local calls, done, finish, response = {}, false
            local iterator = request(chat.endpoint, "text/event-stream", value)
            local event = next_value(iterator)
            while event do
                if event.type == "response" then
                    response = event
                else
                    for _, record in ipairs(parser(event.data)) do
                        if record.data == "[DONE]" then
                            done = true
                        else
                            local item = json.decode(record.data, 1, null)
                            assert(type(item) == "table" and type(item.error) ~= "table", "invalid chat event")
                            local choice = item.choices and item.choices[1]
                            if choice then
                                local delta = assert(choice.delta, "chat event has no delta")
                                local reasoning = delta.reasoning_content or delta.reasoning
                                if reasoning and reasoning ~= null and reasoning ~= "" then
                                    coroutine.yield({ type = "reasoning", text = reasoning })
                                end
                                if delta.content and delta.content ~= null and delta.content ~= "" then
                                    coroutine.yield({ type = "response", text = delta.content })
                                end
                                for _, entry in ipairs(delta.tool_calls == null and {} or delta.tool_calls or {}) do
                                    local index = assert(math.tointeger(entry.index), "chat tool index is invalid") + 1
                                    local call, fn = calls[index] or {}, entry["function"] or {}
                                    calls[index] = call
                                    for field, fragment in pairs({
                                        id = entry.id,
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
            for _, record in ipairs(parser()) do
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
                #decoded <= chat.maximum_parallel_tools and (#decoded > 0) == (finish == "tool_calls"),
                "parallel tool limit"
            )
            coroutine.yield({ type = "finish", reason = finish, calls = decoded, wire = wire })
        end)
    end

    function api:rerank(query, passages)
        if #passages == 0 then
            return {}
        end
        local selected = {}
        for _, passage in ipairs(passages) do
            if tokens(rerank, query .. "\n" .. passage) > rerank.passage_tokens then
                break
            end
            selected[#selected + 1] = passage
        end
        assert(#selected > 0, "first reranker passage exceeds the token budget")
        local value = post(rerank, rerank.endpoint, {
            documents = selected,
            query = query,
            top_n = #selected,
        })
        local result, seen = {}, {}
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
            seen[index], result[#result + 1] = true, index + 1
        end
        return result
    end
    return api
end
