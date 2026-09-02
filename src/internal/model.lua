local json = require("lunajson")
local null = {}
local TOOL = { type = "function", ["function"] = { name = "run_lua", parameters = { type = "object", required = { "code" }, properties = { code = { type = "string" } } } } }

local function portable(value, seen)
    local kind = type(value)
    if kind == "nil" or kind == "boolean" then
        return value
    elseif kind == "string" then
        assert(utf8.len(value), "value is not UTF-8")
        return value
    elseif kind == "number" then
        assert(value == value and value ~= math.huge and value ~= -math.huge, "value is not finite")
        return value
    end
    assert(kind == "table" and not seen[value], kind == "table" and "value contains a cycle" or "unsupported value"); seen[value] = true
    local output, count, numeric, textual = {}, rawget(value, 0), false, false
    if count ~= nil then assert(math.type(count) == "integer" and count >= 0, "array count is invalid") end
    for key in next, value do
        if key ~= 0 or count == nil then
            if type(key) == "number" then
                assert(math.type(key) == "integer" and key > 0, "array key is invalid")
                numeric = true
            else
                assert(type(key) == "string" and utf8.len(key), "object key is invalid")
                textual = true
            end
        end
    end
    assert(not (numeric and textual) and not (count ~= nil and textual), "table is mixed")
    if count == nil and numeric then
        for key in next, value do
            if type(key) == "number" and key > (count or 0) then
                count =
                    key
            end
        end
    end
    if count ~= nil then
        output[0] = count; for index = 1, count do
            assert(rawget(value, index) ~= nil, "array is sparse")
            output[index] = portable(rawget(value, index), seen)
        end; for key in next, value do assert(key == 0 or type(key) == "number" and key <= count, "array is sparse") end
    else
        for key, item in next, value do output[key] = portable(item, seen) end
    end
    seen[value] = nil; return output
end

local function dense(value, name)
    assert(type(value) == "table", name .. " must be an array")
    local size = #value
    for key in pairs(value) do assert(math.type(key) == "integer" and key >= 1 and key <= size, name .. " must be dense") end
    return value
end

return function(config, http)
    local chat, rerank = config.chat, config.rerank
    local context = assert(math.tointeger(chat.context_tokens), "model context must be an integer")
    assert(context > 0, "model context must be positive")
    local function request(endpoint, accept, value, limits)
        local response = http({
            url = endpoint,
            method = "POST",
            body = json.encode(value, null),
            headers = { ["content-type"] = "application/json", accept = accept },
            limits =
                limits and limits.http
        })
        assert(response.status >= 200 and response.status < 300, "model endpoint failed")
        return response.body
    end
    local function post(model, endpoint, value, limits)
        value.model = model.model
        local result = json.decode(request(endpoint, "application/json", value, limits), 1, null)
        assert(type(result) == "table" and type(result.error) ~= "table", "invalid model response")
        return result
    end
    local function tokens(model, content, special, limits)
        local result = post(model, model.tokenize,
            { content = content, add_special = false, parse_special = special or false }, limits)
        return #dense(result.tokens, "tokenizer tokens")
    end
    local api = {}
    function api:encode(value) return json.encode(portable(value, {}), null) end

    function api:tokens(content, limits) return tokens(chat, content, false, limits) end

    function api:chat(messages, emit, limits)
        limits = limits or {}
        local value = { messages = messages, tools = { TOOL }, parallel_tool_calls = false, add_generation_prompt = true }
        local prompt = assert(post(chat, chat.template, value, limits).prompt, "template response has no prompt")
        local used = tokens(chat, prompt, true, limits)
        local maximum = limits.maximum_output_tokens
        assert(used < context and (not maximum or used + maximum <= context), "model prompt exceeds context")
        value.add_generation_prompt, value.stream, value.max_tokens = nil, true, maximum or context - used
        local calls, finish, done = {}, nil, false
        local function data(source)
            assert(not done, "chat data follows completion")
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
            if delta.content and delta.content ~= null and delta.content ~= "" then
                emit({
                    type = "response",
                    text =
                        delta.content
                })
            end
            for _, entry in ipairs(delta.tool_calls == null and {} or dense(delta.tool_calls or {}, "chat tool calls")) do
                local index = assert(math.tointeger(entry.index), "chat tool index is invalid")
                assert(index >= 0 and (not limits.maximum_tool_calls or index < limits.maximum_tool_calls),
                    "tool call limit")
                index = index + 1
                local call, fn = calls[index] or {}, entry["function"] or {}
                calls[index] = call
                if entry.id and entry.id ~= null then call.id = (call.id or "") .. entry.id end
                if fn.name and fn.name ~= null then call.name = (call.name or "") .. fn.name end
                if fn.arguments and fn.arguments ~= null then call.arguments = (call.arguments or "") .. fn.arguments end
            end
            if choice.finish_reason ~= null and choice.finish_reason ~= nil then
                assert(not finish or finish == choice.finish_reason, "conflicting finish reason")
                finish = choice.finish_reason
            end
        end
        local body = request(chat.endpoint, "text/event-stream", value, limits):gsub("\r\n", "\n")
        local offset = 1
        for ending in body:gmatch("()\n\n") do
            local event = body:sub(offset, ending - 1)
            assert(not limits.maximum_event_bytes or #event <= limits.maximum_event_bytes, "chat event is too large")
            local payload = {}
            for line in event:gmatch("[^\n]+") do
                local item = line:match("^data: ?(.*)$")
                if item then payload[#payload + 1] = item end
            end
            if #payload > 0 then data(table.concat(payload, "\n")) end
            offset = ending + 2
        end
        assert(body:sub(offset) == "" and done and ({ stop = true, tool_calls = true, length = true })[finish],
            "chat stream ended incompletely")
        local count, highest = 0, 0
        for index in pairs(calls) do
            assert(math.type(index) == "integer" and index > 0, "invalid tool call index")
            count, highest = count + 1, math.max(highest, index)
        end
        assert(count == highest and (not limits.maximum_tool_calls or count <= limits.maximum_tool_calls),
            "tool calls are sparse")
        local decoded, wire, ids = {}, {}, {}
        for index = 1, highest do
            local call = calls[index]
            assert(
                call.name == "run_lua" and type(call.id) == "string" and call.id ~= "" and not ids[call.id] and
                type(call.arguments) == "string", "invalid tool call")
            local arguments = json.decode(call.arguments, 1, null)
            assert(type(arguments) == "table" and type(arguments.code) == "string", "invalid tool arguments"); for key in pairs(arguments) do
                assert(key == "code", "invalid tool arguments")
            end
            ids[call.id] = true
            decoded[index] = { id = call.id, code = arguments.code }
            wire[index] = { id = call.id, type = "function", ["function"] = { name = "run_lua", arguments = call.arguments } }
        end
        assert((#decoded > 0) == (finish == "tool_calls"), "invalid tool completion")
        return { calls = decoded, wire = wire }
    end

    function api:rerank(query, passages, limits)
        if #passages == 0 then return {} end
        local selected = {}
        for _, passage in ipairs(passages) do
            if tokens(rerank, query .. "\n" .. passage, false, limits) > rerank.passage_tokens then break end
            selected[#selected + 1] = passage
        end
        assert(#selected > 0, "first reranker passage exceeds model context")
        local ranked = post(rerank, rerank.endpoint, { documents = selected, query = query, top_n = #selected }, limits)
            .results
        dense(ranked, "reranker results"); assert(#ranked == #selected, "reranker response has the wrong count")
        local result, seen = {}, {}
        for _, item in ipairs(ranked) do
            local index = type(item) == "table" and math.tointeger(item.index)
            assert(
                index and index >= 0 and index < #selected and not seen[index] and type(item.relevance_score) == "number",
                "reranker item is invalid")
            seen[index], result[#result + 1] = true, index + 1
        end
        return result
    end

    return api
end
