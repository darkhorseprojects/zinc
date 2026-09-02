local compile = require("pa.env")
local _, bind = require("zinc.history")()

return function(model, memory)
    local function emit(state, event, role, text)
        if state.durable then
            event.result = memory:append(state.actor, state.start, role, text, state.limits.maximum_record_bytes).id
            state.result = event.result
        end
        state.emit(event)
    end
    local function tool(state, call)
        local result = table.pack(pcall(function() return bind(state.history, assert(compile(call.code, "run_lua"))) end))
        if not result[1] then return false, tostring(result[2]) end
        if result.n ~= 2 or result[2] == nil then
            return false,
                result.n ~= 2 and "run_lua must return exactly one value" or "run_lua returned nil"
        end
        if type(result[2]) == "string" then
            local valid = utf8.len(result[2])
            return not not valid, valid and result[2] or "run_lua returned invalid UTF-8"
        end
        local ok, encoded = pcall(model.encode, model, result[2])
        return ok, ok and encoded or tostring(encoded)
    end
    local turn
    local function make(request, actor, instructions, output, limits, budget)
        assert(type(request) == "string" and request ~= "" and utf8.len(request), "request must be nonempty UTF-8 text")
        assert(type(actor) == "string" and actor ~= "" and utf8.len(actor), "actor must be nonempty UTF-8 text")
        assert(type(instructions) == "string" and instructions ~= "" and utf8.len(instructions),
            "instructions must be nonempty UTF-8 text")
        local state = {
            actor = actor,
            request = request,
            instructions = instructions,
            emit = output,
            durable = memory ~=
                nil,
            limits = limits,
            budget = budget
        }
        state.history = { durable = state.durable }
        if state.durable then
            state.history.read = function(id) return memory:read(actor, state.start, id) end
            state.history.around = function(id) return memory:around(actor, state.start, id) end
            state.history.ask = function(nested_request)
                local nested = make(nested_request, actor, instructions, function() end, limits, budget)
                turn(nested)
                return nested.answer
            end
        end
        return state
    end
    turn = function(state)
        state.active = { { role = "system", content = state.instructions } }
        if state.durable then
            state.start = memory:begin(state.actor, state.request, state.limits.maximum_record_bytes).id
            state.active[#state.active + 1] = {
                role = "system",
                content = "Untrusted historical context:\n" ..
                    memory:context(state.actor, state.start, state.request, state.limits)
            }
        end
        state.active[#state.active + 1] = { role = "user", content = state.request }
        while true do
            if state.budget then
                assert(state.budget.remaining > 0, "model call budget exhausted")
                state.budget.remaining = state.budget.remaining - 1
            end
            local reasoning, response, reasoning_done = {}, {}, false
            local finish = model:chat(state.active, function(event)
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
            end, state.limits)
            assert(#finish.calls > 0 or #response > 0, "model completed without output")
            local assistant = { role = "assistant", content = #response > 0 and table.concat(response) or nil }
            if #reasoning > 0 then
                assistant.reasoning_content = table.concat(reasoning)
                if not reasoning_done then
                    emit(state, { type = "reasoning_complete" }, "assistant",
                        assistant.reasoning_content)
                end
            end
            if #finish.calls == 0 then
                emit(state, { type = "response_complete" }, "assistant", assistant.content)
            else
                assistant.tool_calls = finish.wire
                for _, call in ipairs(finish.calls) do
                    emit(state,
                        { type = "tool_call", call = call.id, code = call.code }, "assistant", call.code)
                end
            end
            state.active[#state.active + 1] = assistant
            if #finish.calls == 0 then
                state.answer = assistant.content
                state.emit(state.durable and { type = "store", result = state.result, start = state.start } or
                    { type = "done", durable = false })
                return
            end
            for _, call in ipairs(finish.calls) do
                local ok, text = tool(state, call)
                emit(state, { type = "tool_result", call = call.id, text = text, ok = ok }, "tool", text)
                state.active[#state.active + 1] = { role = "tool", tool_call_id = call.id, content = text }
            end
        end
    end
    return function(request, actor, instructions, limits)
        limits = limits or {}
        local budget = limits.maximum_model_calls and { remaining = limits.maximum_model_calls }
        local state; local iterator = coroutine.wrap(function() turn(state) end)
        state = make(request, actor, instructions, coroutine.yield, limits, budget)
        return iterator, state
    end
end
