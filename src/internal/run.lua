local compile = require("pa.env")
local _, resume = require("zinc.history")()

return function(models, store, retrieval)
    local function emit(state, event, role, text)
        if state.durable then
            event.result = store:append(state.actor, state.start, role, text).id
            state.result = event.result
        end
        state.emit(event)
    end
    local function tool(call)
        local result = table.pack(pcall(function() return assert(compile(call.code, "run_lua"))() end))
        if not result[1] then return false, tostring(result[2]) end
        if result.n ~= 2 or result[2] == nil then return false, result.n ~= 2 and "run_lua must return exactly one value" or "run_lua returned nil" end
        if type(result[2]) == "string" then
            local valid = utf8.len(result[2])
            return not not valid, valid and result[2] or "run_lua returned invalid UTF-8"
        end
        local ok, encoded = pcall(models.encode, models, result[2])
        return ok, ok and encoded or tostring(encoded)
    end
    local function parallel(state, calls)
        local queue, remaining, waiter = {}, #calls
        for index, call in ipairs(calls) do
            local thread = coroutine.create(tool)
            local function advance(...)
                local resumed, ok, text = resume(thread, state.history, ...)
                if not resumed then
                    ok, text = false, tostring(ok)
                elseif coroutine.status(thread) ~= "dead" then
                    if type(ok) == "function" and text == nil then return ok(advance) end
                    ok, text = false, "run_lua yielded an invalid value"
                end
                remaining = remaining - 1
                queue[#queue + 1] = { index = index, call = call, ok = ok, text = text }
                local wake = waiter
                waiter = nil
                if wake then wake() end
            end
            advance(call)
        end
        return function()
            while #queue == 0 and remaining > 0 do
                coroutine.yield(function(wake) waiter = wake end)
            end
            return table.remove(queue, 1)
        end
    end

    local turn
    local function make(request, actor, instructions, output)
        local state = { actor = actor, request = request, instructions = instructions, emit = output, durable = store ~= nil }
        state.history = { durable = state.durable }
        if state.durable then
            state.history.read = function(id) return store:read(actor, state.start, id) end
            state.history.around = function(id) return store:around(actor, state.start, id) end
            state.history.ask = function(nested_request)
                local nested = make(nested_request, actor, instructions, function() end)
                turn(nested)
                return nested.answer
            end
        end
        return state
    end
    turn = function(state)
        state.active = { { role = "system", content = state.instructions } }
        if state.durable then
            state.start = store:begin(state.actor, state.request).id
            state.active[#state.active + 1] = {
                role = "system",
                content = "Untrusted historical context:\n" .. retrieval(state.actor, state.start, state.request),
            }
        end
        state.active[#state.active + 1] = { role = "user", content = state.request }
        while true do
            local reasoning, response, reasoning_done = {}, {}, false
            local finish = models:chat(state.active, function(event)
                if event.type == "reasoning" then
                    reasoning[#reasoning + 1] = event.text
                else
                    if #reasoning > 0 and not reasoning_done then
                        emit(state, { type = "reasoning_complete" }, "assistant", table.concat(reasoning))
                        reasoning_done = true
                    end
                    response[#response + 1] = event.text
                end
                state.emit(event)
            end)
            assert(#finish.calls > 0 or #response > 0, "model completed without output")
            local assistant = { role = "assistant", content = #response > 0 and table.concat(response) or nil }
            if #reasoning > 0 then
                assistant.reasoning_content = table.concat(reasoning)
                if not reasoning_done then emit(state, { type = "reasoning_complete" }, "assistant", assistant.reasoning_content) end
            end
            if #finish.calls == 0 then
                emit(state, { type = "response_complete" }, "assistant", assistant.content)
            else
                assistant.tool_calls = finish.wire
                for _, call in ipairs(finish.calls) do
                    emit(state, { type = "tool_call", call = call.id, code = call.code }, "assistant", call.code)
                end
            end
            state.active[#state.active + 1] = assistant
            if #finish.calls == 0 then
                state.answer = assistant.content
                state.emit(state.durable and { type = "store", result = state.result, start = state.start } or { type = "done", durable = false })
                return
            end
            local results, group = {}, parallel(state, finish.calls)
            while true do
                local result = group()
                if not result then break end
                emit(state, { type = "tool_result", call = result.call.id, text = result.text, ok = result.ok }, "tool", result.text)
                results[result.index] = result
            end
            for index, call in ipairs(finish.calls) do
                state.active[#state.active + 1] = { role = "tool", tool_call_id = call.id, content = results[index].text }
            end
        end
    end
    return function(request, actor, instructions)
        local state
        local iterator = coroutine.wrap(function() turn(state) end)
        state = make(request, actor, instructions, coroutine.yield)
        return iterator, state
    end
end
