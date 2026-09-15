local json = require("src.json")
local pa = require("pa")

local TOOL = {
    type = "function",
    ["function"] = {
        name = "run_lua",
        description = "Run Lua with self and input prebound; return one string. Operations take byte strings.",
        parameters = {
            type = "object",
            additionalProperties = false,
            required = { "code" },
            properties = { code = { type = "string" } },
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

return function(config)
    local chat, rerank = config.chat, config.rerank
    assert(type(config.origin) == "string" and config.origin ~= "", "invalid model origin")
    assert(type(chat) == "table" and type(rerank) == "table", "invalid model configuration")
    for _, endpoint in ipairs({ chat.endpoint, chat.template, chat.tokenize, rerank.endpoint, rerank.tokenize }) do
        assert(type(endpoint) == "string" and endpoint:sub(1, 1) == "/", "invalid model endpoint")
    end
    local numeric = {
        "context_tokens",
        "maximum_output_tokens",
        "maximum_tool_calls",
        "maximum_tool_source_bytes",
        "maximum_tool_argument_bytes",
        "maximum_event_bytes",
        "maximum_response_bytes",
        "maximum_item_bytes",
        "maximum_events",
    }
    for _, name in ipairs(numeric) do
        assert(math.type(chat[name]) == "integer" and chat[name] > 0, "invalid chat limit: " .. name)
    end
    assert(
        type(chat.model) == "string" and chat.model ~= "" and type(rerank.model) == "string" and rerank.model ~= "",
        "invalid model name"
    )
    assert(math.type(rerank.passage_tokens) == "integer" and rerank.passage_tokens > 0, "invalid reranker limit")
    local context = chat.context_tokens

    local function request(path, accept, value)
        local status, body = pa.http(config.origin, "POST", path, json.encode(value), {
            ["content-type"] = "application/json",
            accept = accept,
        })
        assert(status >= 200 and status < 300, "model endpoint failed")
        return body
    end

    local function post(model, path, value)
        value.model = model.model
        local result = json.decode(request(path, "application/json", value))
        assert(type(result) == "table" and type(result.error) ~= "table", "invalid model response")
        return result
    end

    local function tokens(model, content, special)
        local result = post(model, model.tokenize, {
            content = content,
            add_special = false,
            parse_special = special or false,
        })
        return #dense(result.tokens, "tokenizer tokens")
    end

    local api = {}
    function api:tokens(content)
        return tokens(chat, content, false)
    end

    function api:chat(messages)
        local value = {
            messages = messages,
            tools = { TOOL },
            parallel_tool_calls = true,
            add_generation_prompt = true,
        }
        local prompt = post(chat, chat.template, value).prompt
        assert(type(prompt) == "string" and utf8.len(prompt), "invalid template prompt")
        local used = tokens(chat, prompt, true)
        assert(used < context and used + chat.maximum_output_tokens <= context, "model prompt exceeds context")
        value.add_generation_prompt, value.stream, value.max_tokens = nil, true, chat.maximum_output_tokens

        local calls, owners, items, finish, done = {}, {}, {}, nil, false
        local function item(kind)
            local current = items[#items]
            if current and current.type == kind then
                return current
            end
            current = { type = kind, fragments = {}, bytes = 0 }
            items[#items + 1] = current
            return current
        end
        local function text(kind, content)
            if content and content ~= json.null and content ~= "" then
                local current = item(kind)
                current.bytes = current.bytes + #content
                assert(current.bytes <= chat.maximum_item_bytes, "model item is too large")
                current.fragments[#current.fragments + 1] = content
            end
        end
        local function append(parts, fragment)
            if fragment and fragment ~= json.null then
                parts[#parts + 1] = fragment
            end
        end
        local function data(source)
            assert(not done, "chat data follows completion")
            if source == "[DONE]" then
                done = true
                return
            end
            local event = json.decode(source)
            assert(type(event) == "table" and type(event.error) ~= "table", "invalid chat event")
            local choice = event.choices and event.choices[1]
            if not choice then
                return
            end
            local delta = assert(choice.delta, "chat event has no delta")
            text("reasoning", delta.reasoning_content or delta.reasoning)
            text("response", delta.content)
            local entries = delta.tool_calls == json.null and {} or dense(delta.tool_calls or {}, "chat tool calls")
            if #entries > 0 then
                local owner = item("tool")
                owner.indices = owner.indices or {}
                for _, entry in ipairs(entries) do
                    local index = assert(math.tointeger(entry.index), "chat tool index is invalid")
                    assert(index >= 0 and index < chat.maximum_tool_calls, "tool call limit")
                    index = index + 1
                    assert(not owners[index] or owners[index] == owner, "tool call fragments are discontiguous")
                    owners[index], owner.indices[index] = owner, true
                    local call = calls[index]
                    if not call then
                        call = { id = {}, name = {}, arguments = {}, argument_bytes = 0 }
                        calls[index] = call
                    end
                    local fn = entry["function"] or {}
                    append(call.id, entry.id)
                    append(call.name, fn.name)
                    if fn.arguments and fn.arguments ~= json.null then
                        call.argument_bytes = call.argument_bytes + #fn.arguments
                        assert(call.argument_bytes <= chat.maximum_tool_argument_bytes, "tool arguments are too large")
                        call.arguments[#call.arguments + 1] = fn.arguments
                    end
                end
            end
            if choice.finish_reason ~= json.null and choice.finish_reason ~= nil then
                assert(not finish or finish == choice.finish_reason, "conflicting finish reason")
                finish = choice.finish_reason
            end
        end

        local body = request(chat.endpoint, "text/event-stream", value)
        assert(#body <= chat.maximum_response_bytes, "chat response is too large")
        body = body:gsub("\r\n", "\n")
        local offset, event_count = 1, 0
        for ending in body:gmatch("()\n\n") do
            local event = body:sub(offset, ending - 1)
            event_count = event_count + 1
            assert(event_count <= chat.maximum_events and #event <= chat.maximum_event_bytes, "chat event limit")
            local payload = {}
            for line in event:gmatch("[^\n]+") do
                local payload_line = line:match("^data: ?(.*)$")
                if payload_line then
                    payload[#payload + 1] = payload_line
                end
            end
            if #payload > 0 then
                data(table.concat(payload, "\n"))
            end
            offset = ending + 2
        end
        assert(body:sub(offset) == "" and done, "chat stream ended incompletely")
        assert(({ stop = true, tool_calls = true, length = true })[finish], "invalid finish reason")

        local count, highest = 0, 0
        for index in pairs(calls) do
            count, highest = count + 1, math.max(highest, index)
        end
        assert(count == highest and count <= chat.maximum_tool_calls, "tool calls are sparse")
        local decoded, wire, ids = {}, {}, {}
        for index = 1, highest do
            local call = calls[index]
            local id = table.concat(call.id)
            local name = table.concat(call.name)
            local arguments_source = table.concat(call.arguments)
            assert(name == "run_lua" and id ~= "" and utf8.len(id) and not ids[id], "invalid tool call")
            local arguments = json.decode(arguments_source)
            assert(type(arguments) == "table" and type(arguments.code) == "string", "invalid tool arguments")
            for key in pairs(arguments) do
                assert(key == "code", "invalid tool arguments")
            end
            assert(
                utf8.len(arguments.code) and #arguments.code <= chat.maximum_tool_source_bytes,
                "invalid tool source"
            )
            ids[id] = true
            decoded[index] = { id = id, code = arguments.code }
            wire[index] = {
                id = id,
                type = "function",
                ["function"] = { name = "run_lua", arguments = arguments_source },
            }
        end
        assert((highest > 0) == (finish == "tool_calls"), "invalid tool completion")

        for _, current in ipairs(items) do
            if current.type == "tool" then
                current.calls, current.wire = {}, {}
                for index = 1, highest do
                    if current.indices[index] then
                        current.calls[#current.calls + 1] = decoded[index]
                        current.wire[#current.wire + 1] = wire[index]
                    end
                end
                current.indices = nil
            else
                current.text = table.concat(current.fragments)
            end
            current.fragments, current.bytes = nil, nil
        end
        assert(#items > 0, "model completed without output")
        return { items = items, last = items[#items].type }
    end

    function api:rerank(query, passages)
        local selected, source = {}, {}
        for index, passage in ipairs(passages) do
            local content = query .. "\n" .. passage
            if #content <= rerank.passage_tokens or tokens(rerank, content, false) <= rerank.passage_tokens then
                selected[#selected + 1], source[#source + 1] = passage, index
            end
        end
        if #selected == 0 then
            return {}
        end
        local ranked = post(rerank, rerank.endpoint, {
            documents = selected,
            query = query,
            top_n = #selected,
        }).results
        dense(ranked, "reranker results")
        assert(#ranked == #selected, "reranker response has the wrong count")
        local result, seen = {}, {}
        for _, entry in ipairs(ranked) do
            local index = type(entry) == "table" and math.tointeger(entry.index)
            assert(index and index >= 0 and index < #selected and not seen[index], "reranker index is invalid")
            assert(finite(entry.relevance_score), "reranker score is invalid")
            seen[index], result[#result + 1] = true, source[index + 1]
        end
        return result
    end

    return api
end
