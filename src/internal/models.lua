local json = require("lunajson")
local null = {}
local TOOL = {
    type = "function",
    ["function"] = {
        name = "run_lua",
        parameters = { type = "object", required = { "code" }, properties = { code = { type = "string" } } },
    },
}

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
        local chunks, event = {}, iterator()
        while event and event.type == "data" do
            chunks[#chunks + 1], event = event.data, iterator()
        end
        assert(event and event.status >= 200 and event.status < 300, "model endpoint failed")
        return table.concat(chunks)
    end
    local function post(model, endpoint, value)
        value.model = model.model
        local result = json.decode(collect(request(endpoint, "application/json", value)), 1, null)
        assert(type(result) == "table" and type(result.error) ~= "table", "invalid model response")
        return result
    end
    local function tokens(model, content, special)
        return #assert(
            post(model, model.tokenize, { content = content, add_special = false, parse_special = special or false }).tokens,
            "tokenizer response has no tokens"
        )
    end
    local api = {}
    function api:encode(value) return json.encode(value, null) end
    function api:tokens(content) return tokens(chat, content) end
    function api:chat(messages, emit)
        local value = { messages = messages, tools = { TOOL }, parallel_tool_calls = true, add_generation_prompt = true }
        local prompt = assert(post(chat, chat.template, value).prompt, "template response has no prompt")
        local used = tokens(chat, prompt, true)
        assert(used + reserve <= context, "model prompt leaves too few output tokens")
        value.add_generation_prompt, value.stream, value.max_tokens = nil, true, context - used
        local iterator = request(chat.endpoint, "text/event-stream", value)
        local calls, finish, pending, done, response = {}, nil, "", false
        local function data(source)
            if source == "[DONE]" then
                done = true
                return
            end
            local item = json.decode(source, 1, null)
            assert(type(item) == "table" and type(item.error) ~= "table", "invalid chat event")
            local choice = item.choices and item.choices[1]
            if not choice then return end
            local delta = assert(choice.delta, "chat event has no delta")
            local reasoning = delta.reasoning_content or delta.reasoning
            if reasoning and reasoning ~= null and reasoning ~= "" then emit({ type = "reasoning", text = reasoning }) end
            if delta.content and delta.content ~= null and delta.content ~= "" then emit({ type = "response", text = delta.content }) end
            for _, entry in ipairs(delta.tool_calls == null and {} or delta.tool_calls or {}) do
                local index = assert(math.tointeger(entry.index), "chat tool index is invalid") + 1
                local call, fn = calls[index] or {}, entry["function"] or {}
                calls[index] = call
                if entry.id and entry.id ~= null then call.id = (call.id or "") .. entry.id end
                if fn.name and fn.name ~= null then call.name = (call.name or "") .. fn.name end
                if fn.arguments and fn.arguments ~= null then call.arguments = (call.arguments or "") .. fn.arguments end
            end
            if choice.finish_reason ~= null then finish = choice.finish_reason or finish end
        end
        local event = iterator()
        while event do
            if event.type == "response" then
                response = event
            else
                pending = (pending .. event.data):gsub("\r\n", "\n")
                local offset = 1
                for ending in pending:gmatch("()\n\n") do
                    local payload = pending:sub(offset, ending - 1):match("^data: ?(.*)$")
                    if payload then data(payload) end
                    offset = ending + 2
                end
                pending = pending:sub(offset)
            end
            event = iterator()
        end
        assert(pending == "" and response and response.status >= 200 and response.status < 300 and done and finish, "chat stream ended incompletely")
        local decoded, wire = {}, {}
        for _, call in ipairs(calls) do
            local arguments = json.decode(call.arguments, 1, null)
            assert(call.name == "run_lua" and type(call.id) == "string", "invalid tool call")
            assert(type(arguments.code) == "string" and next(arguments, "code") == nil, "invalid tool arguments")
            decoded[#decoded + 1] = { id = call.id, code = arguments.code }
            wire[#wire + 1] = { id = call.id, type = "function", ["function"] = { name = "run_lua", arguments = call.arguments } }
        end
        assert(#decoded <= chat.maximum_parallel_tools and (#decoded > 0) == (finish == "tool_calls"), "parallel tool limit")
        return { reason = finish, calls = decoded, wire = wire }
    end
    function api:rerank(query, passages)
        if #passages == 0 then return {} end
        local selected = {}
        for _, passage in ipairs(passages) do
            if tokens(rerank, query .. "\n" .. passage) > rerank.passage_tokens then break end
            selected[#selected + 1] = passage
        end
        assert(#selected > 0, "first reranker passage exceeds the token budget")
        local ranked = post(rerank, rerank.endpoint, { documents = selected, query = query, top_n = #selected }).results
        assert(type(ranked) == "table" and #ranked == #selected, "reranker response has the wrong count")
        local result, seen = {}, {}
        for _, item in ipairs(ranked) do
            local index = type(item) == "table" and math.tointeger(item.index)
            assert(index and index >= 0 and index < #selected and not seen[index] and type(item.relevance_score) == "number", "reranker item is invalid")
            seen[index], result[#result + 1] = true, index + 1
        end
        return result
    end
    return api
end
