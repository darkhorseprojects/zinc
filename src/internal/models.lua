local json = require("lunajson")
local null = {}
local tool = {
    type = "function",
    ["function"] = {
        name = "run_lua",
        parameters = { type = "object", required = { "code" }, properties = { code = { type = "string" } } },
    },
}

local function next_value(iterator, ...)
    local value = iterator(...)
    while type(value) == "function" do
        value = iterator(coroutine.yield(value))
    end
    return value
end
local function events(pending, chunk)
    pending = (pending .. chunk):gsub("\r\n", "\n")
    local output, offset = {}, 1
    for ending in pending:gmatch("()\n\n") do
        local data = pending:sub(offset, ending - 1):match("^data: ?(.*)$")
        if data then
            output[#output + 1] = data
        end
        offset = ending + 2
    end
    return pending:sub(offset), output
end

return function(config, http)
    local chat, rerank = config.chat, config.rerank
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
    local function collect(iterator)
        local chunks, event = {}, next_value(iterator)
        while event and event.type == "data" do
            chunks[#chunks + 1] = event.data
            event = next_value(iterator)
        end
        assert(event and event.status >= 200 and event.status < 300, "model endpoint failed")
        return table.concat(chunks)
    end
    local function post(model, endpoint, value)
        value.model = model.model
        local decoded = json.decode(collect(request(endpoint, "application/json", value)), 1, null)
        assert(type(decoded) == "table" and type(decoded.error) ~= "table", "invalid model response")
        return decoded
    end
    local function tokens(model, content, special)
        local value =
            post(model, model.tokenize, { content = content, add_special = false, parse_special = special or false })
        return #assert(value.tokens, "tokenizer response has no tokens")
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
                parallel_tool_calls = true,
                add_generation_prompt = true,
            }
            local template = post(chat, chat.template, value)
            local used = tokens(chat, assert(template.prompt, "template response has no prompt"), true)
            assert(used + reserve <= context, "model prompt leaves too few output tokens")
            value.add_generation_prompt, value.stream, value.max_tokens = nil, true, context - used

            local iterator = request(chat.endpoint, "text/event-stream", value)
            local calls, finish, pending, done, response = {}, nil, "", false
            local event = next_value(iterator)
            while event do
                if event.type == "response" then
                    response = event
                else
                    local records
                    pending, records = events(pending, event.data)
                    for _, data in ipairs(records) do
                        if data == "[DONE]" then
                            done = true
                        else
                            local item = json.decode(data, 1, null)
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
                                    if entry.id and entry.id ~= null then
                                        call.id = (call.id or "") .. entry.id
                                    end
                                    if fn.name and fn.name ~= null then
                                        call.name = (call.name or "") .. fn.name
                                    end
                                    if fn.arguments and fn.arguments ~= null then
                                        call.arguments = (call.arguments or "") .. fn.arguments
                                    end
                                end
                                if choice.finish_reason ~= null then
                                    finish = choice.finish_reason or finish
                                end
                            end
                        end
                    end
                end
                event = next_value(iterator)
            end
            assert(
                pending == "" and response and response.status >= 200 and response.status < 300 and done and finish,
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
        local ranked = post(rerank, rerank.endpoint, { documents = selected, query = query, top_n = #selected }).results
        assert(type(ranked) == "table" and #ranked == #selected, "reranker response has the wrong count")
        local result, seen = {}, {}
        for _, item in ipairs(ranked) do
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
