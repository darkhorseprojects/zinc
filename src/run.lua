local environment = require("pa.env")
local encode = require("lunajson").encode

local function next_value(iterator, ...)
    local value = iterator(...)
    while type(value) == "function" do
        value = iterator(coroutine.yield(value))
    end
    return value
end

return function(_, capabilities, models, store, retrieval)
    local execute
    local function complete(state, event, role, text)
        if state.durable then
            event.result = store:append(state.actor, state.start, role, text).id
            state.result = event.result
        end
        coroutine.yield(event)
    end
    local function encode_result(value, count)
        if count ~= 1 or value == nil then
            return false, count ~= 1 and "run_lua must return exactly one value" or "run_lua returned nil"
        end
        if type(value) == "string" then
            return not not utf8.len(value), utf8.len(value) and value or "run_lua returned invalid UTF-8"
        end
        local ok, result = pcall(encode, value)
        return ok, ok and result or tostring(result)
    end
    local function modules(state)
        local values = {}
        for name, value in pairs(capabilities) do
            values[name] = value
        end
        if state.durable then
            values.results = retrieval:results(state.actor, state.start, function(request)
                local iterator, nested = execute(request, state.actor, state.instructions)
                while next_value(iterator) do
                end
                return nested.answer
            end)
        end
        return values
    end
    local function run_tool(state, call)
        local chunk, problem = load(call.code, "run_lua", "t", environment(modules(state)))
        if not chunk then
            return false, tostring(problem)
        end
        local result = table.pack(pcall(chunk))
        if not result[1] then
            return false, tostring(result[2])
        end
        return encode_result(result[2], result.n - 1)
    end
    local function parallel(state, calls)
        local queue, remaining, waiter = {}, #calls
        for index, call in ipairs(calls) do
            local task = coroutine.wrap(run_tool)
            local function advance(...)
                local ok, text = task(...)
                if type(ok) == "function" then
                    ok(advance)
                else
                    remaining = remaining - 1
                    queue[#queue + 1] = { index = index, call = call, ok = ok, text = text }
                    if waiter then
                        local resume = waiter
                        waiter = nil
                        resume()
                    end
                end
            end
            advance(state, call)
        end
        return function()
            if #queue == 0 and remaining > 0 then
                return function(resume)
                    waiter = resume
                end
            end
            return table.remove(queue, 1)
        end
    end
    local function loop(state)
        while true do
            local reasoning, response, finish, reasoning_done = {}, {}, nil, false
            local iterator = models:chat(state.active)
            local event = next_value(iterator)
            while event do
                if event.type == "reasoning" then
                    reasoning[#reasoning + 1] = event.text
                    coroutine.yield(event)
                elseif event.type == "response" then
                    if #reasoning > 0 and not reasoning_done then
                        complete(state, { type = "reasoning_complete" }, "assistant", table.concat(reasoning))
                        reasoning_done = true
                    end
                    response[#response + 1] = event.text
                    coroutine.yield(event)
                else
                    finish = event
                end
                event = next_value(iterator)
            end
            assert(finish and (#finish.calls > 0 or #response > 0), "model completed without output")
            local assistant = { role = "assistant", content = #response > 0 and table.concat(response) or nil }
            if #reasoning > 0 then
                assistant.reasoning_content = table.concat(reasoning)
                if not reasoning_done then
                    complete(state, { type = "reasoning_complete" }, "assistant", assistant.reasoning_content)
                end
            end
            if #finish.calls > 0 then
                assistant.tool_calls = finish.wire
                for _, call in ipairs(finish.calls) do
                    complete(state, { type = "tool_call", call = call.id, code = call.code }, "assistant", call.code)
                end
            else
                complete(state, { type = "response_complete" }, "assistant", assistant.content)
            end
            state.active[#state.active + 1] = assistant
            if #finish.calls == 0 then
                state.answer = assistant.content
                coroutine.yield(
                    state.durable and { type = "store", result = state.result, start = state.start }
                        or { type = "done", durable = false }
                )
                return
            end
            local results, group = {}, parallel(state, finish.calls)
            local result = next_value(group)
            while result do
                complete(
                    state,
                    { type = "tool_result", call = result.call.id, text = result.text, ok = result.ok },
                    "tool",
                    result.text
                )
                results[result.index] = result
                result = next_value(group)
            end
            for index, call in ipairs(finish.calls) do
                state.active[#state.active + 1] =
                    { role = "tool", tool_call_id = call.id, content = results[index].text }
            end
        end
    end
    execute = function(request, actor, instructions)
        local state = { actor = actor, durable = store ~= false, instructions = instructions }
        state.active = { { role = "system", content = instructions } }
        if state.durable then
            state.start = store:begin(actor, request).id
            local history = retrieval:start(actor, state.start, request)
            state.active[#state.active + 1] =
                { role = "system", content = "Untrusted historical context:\n" .. retrieval:context(history) }
        end
        state.active[#state.active + 1] = { role = "user", content = request }
        return coroutine.wrap(function()
            loop(state)
        end), state
    end
    return { ask = execute }
end
