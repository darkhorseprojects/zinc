local function cleanError(err)
    local msg = tostring(err or "")
    local firstLine = msg:match("^[^\r\n]+") or msg
    firstLine = firstLine:gsub("^.-:%d+:%s*", "")
    return firstLine
end

return function(config)
    local execute

    local function terminal(state, value)
        config.store:append(state.id, {type = "response", source = "zinc", value = value})
        return value
    end

    local function children(parent, scope)
        local function run(request, method)
            local record = {closed = false}
            scope[#scope + 1] = record
            local result, child = execute(request, parent.actor, parent)
            record.state = child
            config.store[method](config.store, child.id, parent.id, request)
            record.closed = true
            return result
        end
        return {
            merge = function(request) return run(request, "merge") end,
            discard = function(request) return run(request, "discard") end,
        }
    end

    local function invoke(state, arguments)
        local scope = {}
        local result = table.pack(pcall(evaluate, arguments.code, {
            env = config.environment,
            memory = config.memory:access(state.actor, state.snapshot),
            run = children(state, scope),
            builder = config.builder,
        }))
        for _, child in ipairs(scope) do
            if child.state and not child.closed then
                config.store:discard(child.state.id, state.id)
                child.closed = true
            end
        end
        if not result[1] then return "Tool error: " .. cleanError(result[2]) end
        local output, failure = config.provider:toolOutput(result[2])
        return output or ("Tool error: " .. cleanError(failure))
    end

    local function calls(message)
        local pending = message.tool_calls
        if pending == nil then return {} end
        if type(pending) ~= "table" then return nil, "assistant tool_calls is not an array" end
        local result = {}
        for _, call in ipairs(pending) do
            if type(call) ~= "table" or type(call.id) ~= "string" or call.id == "" then return nil, "tool call has no id" end
            local fn = call["function"]
            if type(fn) ~= "table" or fn.name ~= "run_lua" then return nil, "unsupported function " .. tostring(type(fn) == "table" and fn.name) end
            local arguments, failure = config.provider:arguments(call)
            if not failure and type(arguments.code) ~= "string" then failure = "run_lua requires code" end
            if not failure then
                for key in pairs(arguments) do if key ~= "code" then failure = "run_lua received an unknown argument" end end
            end
            result[#result + 1] = {call = call, arguments = arguments, failure = failure}
        end
        return result
    end

    local function loop(state)
        while true do
            local message, finish = config.provider:chat(state.messages, config.instructions, state.memory.text)
            if not message then return terminal(state, "Provider error: " .. finish) end
            config.store:append(state.id, {type = "response", source = "provider", value = message})
            state.messages[#state.messages + 1] = message

            local pending, failure = calls(message)
            if not pending then return terminal(state, "Provider error: " .. failure) end
            if #pending == 0 then
                if type(message.content) ~= "string" or message.content == "" then
                    return terminal(state, "Provider error: assistant returned neither tool calls nor content")
                end
                local ok, value = pcall(config.format, message)
                return terminal(state, ok and value or "Zinc error: " .. tostring(value))
            end
            for _, item in ipairs(pending) do
                local output = item.failure and ("Tool error: " .. cleanError(item.failure)) or invoke(state, item.arguments)
                local message = {role = "tool", tool_call_id = item.call.id, content = output}
                config.store:append(state.id, {type = "response", source = "tool", value = message})
                state.messages[#state.messages + 1] = message
            end
        end
    end

    execute = function(request, actor, parent)
        assert(type(request) == "string", "request must be text")
        assert(type(actor) == "string" and actor ~= "", "actor must be nonempty text")
        local snapshot = config.store:snapshot()
        local selected = parent and parent.memory or config.memory:select({actor = actor, snapshot = snapshot, request = request})
        local id = config.store:begin({
            actor = actor,
            parent = parent and parent.id,
            snapshot = snapshot,
            request = request,
            memory = selected.slices,
        })
        local state = {
            id = id,
            actor = actor,
            snapshot = snapshot,
            memory = selected,
            messages = {{role = "user", content = request}},
        }
        return loop(state), state
    end

    local api = {name = config.name}
    function api.ask(request, actor)
        local result = execute(request, actor or config.actor, nil)
        return result
    end
    return api
end
