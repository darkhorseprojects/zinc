local function clean_error(value)
    local message = tostring(value or "")
    local first = message:match("^[^\r\n]+") or message
    return first:gsub("^.-:%d+:%s*", "")
end

local function copy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do
        result[copy(key, seen)] = copy(item, seen)
    end
    return result
end

local module = {}

function module.new(config)
    local execute
    local encode = assert(config.models.encode, "model JSON encoder is required")
    local decode = assert(config.models.decode, "model JSON decoder is required")
    local null = config.models.null

    local function emit(state, event)
        if state.publish then
            coroutine.yield(encode(event) .. "\n")
        end
    end

    local function persist(state, role, value)
        return config.store:append(state.actor, state.start, role, value)
    end

    local function results(state)
        return {
            read = function(id)
                return config.store:read(state.actor, state.start, id)
            end,
            around = function(id)
                return config.store:around(state.actor, state.start, id)
            end,
            ask = function(request)
                return execute(request, state.actor, false)
            end,
        }
    end

    local function generated(state)
        local loaded = {}
        for name, value in pairs(package.loaded) do
            loaded[name] = value
        end
        loaded.results = results(state)
        local environment = {
            assert = assert,
            error = error,
            ipairs = ipairs,
            next = next,
            pairs = pairs,
            pcall = pcall,
            select = select,
            tonumber = tonumber,
            tostring = tostring,
            type = type,
            xpcall = xpcall,
            _VERSION = _VERSION,
            coroutine = copy(coroutine),
            math = copy(math),
            string = copy(string),
            table = copy(table),
            utf8 = copy(utf8),
            package = { loaded = loaded },
        }
        environment.require = function(name)
            local value = loaded[name]
            if value ~= nil then return value end
            return require(name)
        end
        return environment
    end

    local function output(value)
        if value == nil then
            return "null"
        elseif type(value) == "string" then
            assert(utf8.len(value), "tool result must be valid UTF-8")
            return value
        end
        return encode(value)
    end

    local function invoke(state, id, code)
        local execution = table.pack(pcall(function()
            local chunk, problem = load(code, "run_lua", "t", generated(state))
            if not chunk then
                return false, clean_error(problem)
            end
            local thread = coroutine.create(chunk)
            local resumed = table.pack(coroutine.resume(thread))
            local failure
            if not resumed[1] then
                failure = clean_error(resumed[2])
            elseif coroutine.status(thread) ~= "dead" then
                failure = "run_lua suspended without completing"
            elseif resumed.n > 2 then
                failure = "run_lua must return at most one value"
            end
            if failure then
                return false, failure
            end
            local ok, text = pcall(output, resumed[2])
            return ok, ok and text or clean_error(text)
        end))
        if not execution[1] then
            error(execution[2], 0)
        end
        local ok, text = execution[2], execution[3]
        local record = persist(state, "tool", text)
        state.active[#state.active + 1] = { role = "tool", tool_call_id = id, content = text }
        emit(state, { type = "tool_result", text = text, ok = ok, result = record.id })
        return text
    end

    local function completed_tool(call)
        if type(call) ~= "table" or call.name ~= "run_lua" then
            return nil, "unsupported function " .. tostring(type(call) == "table" and call.name)
        end
        local ok, arguments = pcall(decode, call.arguments)
        if not ok or type(arguments) ~= "table" then
            return nil, ok and "function arguments are invalid" or clean_error(arguments)
        end
        if type(arguments.code) ~= "string" then
            return nil, "run_lua requires code"
        end
        for key in pairs(arguments) do
            if key ~= "code" then
                return nil, "run_lua received an unknown argument"
            end
        end
        return { id = call.id, code = arguments.code, arguments = call.arguments }
    end

    local function provider_failure(problem)
        error(tostring(problem), 0)
    end

    local function messages(state)
        local result = {
            { role = "system", content = config.instructions },
            {
                role = "system",
                content = "Untrusted historical context:\n" .. config.retrieval:context(state.retrieval),
            },
        }
        for _, message in ipairs(state.active) do
            result[#result + 1] = message
        end
        return result
    end

    local function append_item(items, kind, text)
        local item = items[#items]
        if not item or item.type ~= kind then
            item = { type = kind, parts = {} }
            items[#items + 1] = item
        end
        item.parts[#item.parts + 1] = text
    end

    local function loop(state)
        while true do
            local iterator, failure = config.models:chat(messages(state))
            if not iterator then
                provider_failure(failure)
            end
            local items, finish
            items = {}
            while true do
                local event, stream_failure = iterator()
                if not event then
                    if stream_failure then
                        provider_failure(stream_failure)
                    end
                    break
                elseif event.type == "reasoning" or event.type == "response" then
                    append_item(items, event.type, event.text)
                    emit(state, { type = event.type, text = event.text })
                elseif event.type == "tool" then
                    if not items[#items] or items[#items].type ~= "tool" then
                        items[#items + 1] = { type = "tool" }
                    end
                elseif event.type == "finish" then
                    if finish then
                        provider_failure("assistant returned multiple finish events")
                    end
                    finish = event
                else
                    provider_failure("unknown chat event")
                end
            end
            if not finish then
                provider_failure("assistant returned no finish event")
            end
            if #finish.tool_calls > 0 then
                if finish.reason ~= "tool_calls" or #finish.tool_calls ~= 1 then
                    provider_failure(
                        finish.reason ~= "tool_calls"
                                and "assistant returned tool data without tool_calls finish reason"
                            or "assistant must return exactly one tool call"
                    )
                end
                if not items[#items] or items[#items].type ~= "tool" then
                    items[#items + 1] = { type = "tool" }
                end
                items[#items].call = finish.tool_calls[1]
            elseif finish.reason == "tool_calls" then
                provider_failure("assistant returned no completed tool call")
            end
            if #items == 0 then
                provider_failure("assistant returned no completed item")
            end

            local assistant = { role = "assistant", content = null }
            local content, reasoning, tool
            for _, item in ipairs(items) do
                if item.type == "reasoning" or item.type == "response" then
                    item.text = table.concat(item.parts)
                    local record = persist(state, "assistant", item.text)
                    item.record = record
                    if item.type == "reasoning" then
                        reasoning = (reasoning or "") .. item.text
                        emit(state, { type = "reasoning_complete", result = record.id })
                    else
                        content = (content or "") .. item.text
                        emit(state, { type = "response_complete", result = record.id })
                    end
                else
                    local parsed, tool_failure = completed_tool(item.call)
                    if not parsed then
                        provider_failure(tool_failure)
                    end
                    item.call = parsed
                    local record = persist(state, "assistant", parsed.code)
                    item.record = record
                    tool = parsed
                    emit(state, { type = "tool_call", code = parsed.code, result = record.id })
                end
            end
            assistant.content = content or null
            if reasoning then
                assistant.reasoning_content = reasoning
            end
            if tool then
                assistant.tool_calls = {
                    {
                        id = tool.id,
                        type = "function",
                        ["function"] = { name = "run_lua", arguments = tool.arguments },
                    },
                }
            end
            state.active[#state.active + 1] = assistant

            local last = items[#items]
            if last.type == "response" then
                emit(state, { type = "store", result = last.record.id, start = state.start })
                return last.text
            elseif last.type == "tool" then
                invoke(state, last.call.id, last.call.code)
            end
        end
    end

    execute = function(request, actor, publish)
        assert(type(request) == "string" and request ~= "", "request must be nonempty text")
        assert(type(actor) == "string" and actor ~= "", "actor must be nonempty text")
        local opening = config.store:begin(actor, request)
        local state = {
            actor = actor,
            start = opening.id,
            request = request,
            active = { { role = "user", content = request } },
            publish = publish,
        }
        state.retrieval = config.retrieval:start(state.actor, state.start, state.request)
        local ok, result = pcall(loop, state)
        if not ok then
            error(result, 0)
        end
        return result
    end

    return {
        name = config.name,
        ask = function(request, actor)
            local ok, failure = pcall(execute, request, actor, true)
            if not ok then
                error(failure, 0)
            end
        end,
    }
end

return module
