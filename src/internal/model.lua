local json = require("lunajson")
local null = {}
local TOOL = { type = "function", ["function"] = { name = "run_lua", parameters = { type = "object", required = { "code" }, properties = { code = { type = "string" } } } } }

return function(config, http)
    local chat, rerank = config.chat, config.rerank
    local context = assert(math.tointeger(chat.context_tokens), "model context must be an integer")
    local reserve = assert(math.tointeger(chat.minimum_output_tokens), "model output reserve must be an integer")
    assert(context > reserve and reserve > 0, "model token limits are invalid")
    local function request(endpoint, accept, value)
        local response = http({ url = endpoint, method = "POST", body = json.encode(value, null), headers = { ["content-type"] = "application/json", accept = accept } })
        assert(response.status >= 200 and response.status < 300, "model endpoint failed")
        return response.body
    end
    local function post(model, endpoint, value)
        value.model = model.model
        local result = json.decode(request(endpoint, "application/json", value), 1, null)
        assert(type(result) == "table" and type(result.error) ~= "table", "invalid model response")
        return result
    end
    local function tokens(model, content, special)
        local result = post(model, model.tokenize, { content = content, add_special = false, parse_special = special or false })
        return #assert(result.tokens, "tokenizer response has no tokens")
    end
    local api = {}
    function api:encode(value) return json.encode(value, null) end
    function api:tokens(content) return tokens(chat, content) end
    function api:chat(messages, emit)
        local value = { messages = messages, tools = { TOOL }, parallel_tool_calls = false, add_generation_prompt = true }
        local prompt = assert(post(chat, chat.template, value).prompt, "template response has no prompt")
        local used = tokens(chat, prompt, true)
        assert(used + reserve <= context, "model prompt leaves too few output tokens")
        value.add_generation_prompt, value.stream, value.max_tokens = nil, true, context - used
        local calls, finish, done = {}, nil, false
        local function data(source)
            if source == "[DONE]" then done = true return end
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
                assert(index <= chat.maximum_tools, "tool call limit")
                local call, fn = calls[index] or {}, entry["function"] or {}
                calls[index] = call
                if entry.id and entry.id ~= null then call.id = (call.id or "") .. entry.id end
                if fn.name and fn.name ~= null then call.name = (call.name or "") .. fn.name end
                if fn.arguments and fn.arguments ~= null then call.arguments = (call.arguments or "") .. fn.arguments end
            end
            if choice.finish_reason ~= null then finish = choice.finish_reason or finish end
        end
        local body = request(chat.endpoint, "text/event-stream", value):gsub("\r\n", "\n")
        local offset = 1
        for ending in body:gmatch("()\n\n") do
            local event = body:sub(offset, ending - 1)
            assert(#event <= chat.event_bytes, "chat event is too large")
            local payload = {}
            for line in event:gmatch("[^\n]+") do local item = line:match("^data: ?(.*)$") if item then payload[#payload + 1] = item end end
            if #payload > 0 then data(table.concat(payload, "\n")) end
            offset = ending + 2
        end
        assert(body:sub(offset) == "" and done and ({ stop = true, tool_calls = true, length = true })[finish], "chat stream ended incompletely")
        local decoded, wire, ids = {}, {}, {}
        for index, call in ipairs(calls) do
            assert(index <= chat.maximum_tools and call.name == "run_lua" and type(call.id) == "string" and not ids[call.id], "invalid tool call")
            local arguments = json.decode(call.arguments, 1, null)
            assert(type(arguments) == "table" and type(arguments.code) == "string" and next(arguments, "code") == nil, "invalid tool arguments")
            ids[call.id] = true
            decoded[#decoded + 1] = { id = call.id, code = arguments.code }
            wire[#wire + 1] = { id = call.id, type = "function", ["function"] = { name = "run_lua", arguments = call.arguments } }
        end
        assert((#decoded > 0) == (finish == "tool_calls"), "invalid tool completion")
        return { calls = decoded, wire = wire }
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
