local make_memory = require("src.memory")
local make_store = require("src.store")
local pa = require("pa")

local CORE_ADAPTER = [[
callable(self,function(_,request) return invoke("zinc_call","call",request) end)
self.destroy=function(branch) return invoke("zinc_destroy","destroy",branch) end
]]
local NESTED_CALL = [[self({preset=P,question=Q,parent=%s,memory=%d}) -> {branch,id,parent,memory,text}
P = %s
self.destroy(branch) -> "destroyed"
local child = self({question="QUESTION",parent=%s,memory=%d})
self.destroy(child.branch)
return child.text]]

local function names(value)
    local result = {}
    for name in pairs(value) do
        result[#result + 1] = name
    end
    table.sort(result)
    return result
end

local function fenced(language, text)
    local size = 3
    for marker in text:gmatch("`+") do
        size = math.max(size, #marker + 1)
    end
    local marker = string.rep("`", size)
    return marker .. language .. "\n" .. text .. "\n" .. marker
end

local function render(name, preset, documents)
    local lines = {
        documents.base,
        documents.presets[name],
    }
    local whitelist = preset.whitelist
    if whitelist.roots then
        lines[#lines + 1] = "Roots"
        for _, root in ipairs(names(whitelist.roots)) do
            local selected = whitelist.roots[root]
            lines[#lines + 1] = root .. " = " .. selected.path .. " [" .. table.concat(selected.operations, ", ") .. "]"
        end
    end
    if whitelist.actions then
        lines[#lines + 1] = "HTTP"
        for _, action in ipairs(names(whitelist.actions)) do
            local selected = whitelist.actions[action]
            lines[#lines + 1] = action .. " = " .. selected.method .. " " .. selected.origin .. selected.path
        end
    end
    lines[#lines + 1] = "Lua"
    lines[#lines + 1] = "Use Lua 5.5. Comments begin with `--`."
    lines[#lines + 1] =
        "`self` and `input` are defined; do not redefine them. Return a non-nil value. Do not use `print`."
    local members, adapters = names(preset.members), { CORE_ADAPTER }
    for _, member in ipairs(members) do
        local descriptor = preset.members[member]
        for _, usage in ipairs(descriptor.usage) do
            lines[#lines + 1] = usage
        end
        adapters[#adapters + 1] = descriptor.adapter
    end
    local targets = { "nil" }
    for _, target in ipairs(preset.targets) do
        targets[#targets + 1] = string.format("%q", target)
    end
    return {
        system = table.concat(lines, "\n"),
        names = members,
        adapters = adapters,
        targets = table.concat(targets, " | "),
    }
end

local function import_prompt()
    local selected, lines = pa.imports(), {}
    table.sort(selected)
    if #selected > 0 then
        lines[1] = "Imports"
        for _, name in ipairs(selected) do
            local document = require(name).document()
            assert(type(document) == "string" and document ~= "", "invalid Import document")
            lines[#lines + 1] = document
        end
    end
    return table.concat(lines, "\n")
end

local function source(prepared, caller, call, code)
    local adapters = table.concat(prepared.adapters, "\n")
    return "local self,input=(function(raw,callable)\nlocal caller="
        .. caller
        .. "\n"
        .. [[local function invoke(member,action,...)
 return raw[member]({caller=caller,action=action,arguments={...}})
end
local self={}
]]
        .. adapters
        .. string.format(
            "\nreturn self,{question=%q,parent=%s,memory=%d}\nend)((...),callable)\ncallable=nil\n",
            call.question,
            call.parent and tostring(call.parent) or "nil",
            call.memory
        )
        .. [[local output=(function()
]]
        .. code
        .. "\nend)()\n"
        .. [[assert(output~=nil,"Lua source returned no value")
return output
]]
end

return function(spec, entry, make_model, documents)
    local prepared = {}
    for name, preset in pairs(spec.presets) do
        prepared[preset] = render(name, preset, documents)
    end

    local runner = {}

    local function execute(store, memory, model, call)
        local selected = prepared[call.preset]
        local imports = import_prompt()
        local parent = call.parent and tostring(call.parent) or "nil"
        local system = selected.system
            .. (imports ~= "" and "\n" .. imports or "")
            .. "\n"
            .. string.format(NESTED_CALL, parent, call.memory, selected.targets, parent, call.memory)
            .. "\nEval quota: "
            .. store:quota(call.run)
            .. " tokens. Sources and results consume it."
        pa.log("memory.context.begin")
        local context = memory:context(call.actor, call.memory, call.branch, call.question)
        pa.log("memory.context.end")
        local user = call.question
        if call.memory ~= 0 then
            user = "History:\n" .. context .. "\n\nQuestion:\n" .. user
        end
        local messages = { { role = "system", content = system }, { role = "user", content = user } }
        if pa.profile then
            pa.log("model.props.begin")
        end
        local context_tokens = model:context()
        if pa.profile then
            pa.log("model.props.end")
        end
        assert(context_tokens >= 120000, "chat model has less than 120k context")
        local maximum_prompt = context_tokens - call.config.models.chat.maximum_output_tokens - 4096

        for _ = 1, call.config.run.max_model_rounds do
            if pa.profile then
                pa.log("model.prompt.begin")
            end
            while model:prompt_tokens(messages) > maximum_prompt do
                assert(#messages > 2, "question and retrieval exceed chat context")
                local count = messages[3].tool_calls and #messages[3].tool_calls or 0
                for _ = 1, count + 1 do
                    table.remove(messages, 3)
                end
            end
            if pa.profile then
                pa.log("model.prompt.end")
            end
            pa.log("model.chat.begin")
            local completion = model:chat(messages)
            pa.log("model.chat.end")
            local assistant = {
                reasoning_content = completion.reasoning,
                content = completion.content,
                tool_calls = #completion.calls > 0 and completion.tool_calls or nil,
                role = "assistant",
            }
            local events = {}
            if completion.reasoning and completion.reasoning ~= "" then
                events[#events + 1] = { kind = "reasoning", text = completion.reasoning }
            end
            if completion.content and completion.content ~= "" then
                events[#events + 1] = { kind = "response", text = completion.content }
            end
            local rows = #events > 0 and store:append(call.branch, events) or {}
            messages[#messages + 1] = assistant
            if #completion.calls == 0 then
                return assert(rows[#rows], "model returned no response")
            end

            local requests = {}
            for index, tool in ipairs(completion.calls) do
                requests[index] = { kind = "call", text = tool.code, tokens = model:tokens(tool.code) }
            end
            local admitted = store:admit(call.branch, requests)
            for _, tool in ipairs(completion.calls) do
                pa.emit(fenced("lua", tool.code))
            end
            local sources, positions = {}, {}
            for index, admission in ipairs(admitted) do
                if admission.accepted then
                    positions[index] = #sources + 1
                    sources[#sources + 1] = source(selected, admission.row.id, call, completion.calls[index].code)
                end
            end

            local evaluated
            if #sources > 0 then
                local view = {
                    zinc_call = entry.zinc_call,
                    zinc_destroy = entry.zinc_destroy,
                }
                for _, name in ipairs(selected.names) do
                    view[name] = entry[name]
                end
                if pa.profile then
                    pa.log("tool.eval.begin")
                end
                local ok, value = pcall(pa.eval, view, sources, "")
                if pa.profile then
                    pa.log("tool.eval.end")
                end
                evaluated = ok and value or {}
                if not ok then
                    for index in ipairs(sources) do
                        evaluated[index] = { false, tostring(value) }
                    end
                end
            else
                evaluated = {}
            end

            local outputs, result_events = {}, {}
            local available = math.max(0, store:quota(call.run))
            for index in ipairs(completion.calls) do
                local admission = admitted[index]
                local position = positions[index]
                if position then
                    local result = evaluated[position]
                    local output
                    if type(result) == "table" and type(result[1]) == "boolean" and type(result[2]) == "string" then
                        output = result[1] and result[2] or "run_lua failed:\n" .. result[2]
                    else
                        output = "run_lua failed: invalid Eval result"
                    end
                    if output:sub(1, 15) == "run_lua failed:" then
                        pa.log("tool.eval.failed")
                    end
                    if output == "" or not utf8.len(output) then
                        output = "run_lua failed: invalid result"
                    end
                    local original_bytes = #output
                    local limit = call.config.run.maximum_tool_result_bytes
                    if original_bytes > limit then
                        local notice = string.format(
                            "\n[result truncated: call #%d, original %d bytes]",
                            admission.row.id,
                            original_bytes
                        )
                        local length = limit - #notice
                        while length > 0 and not utf8.len(output:sub(1, length)) do
                            length = length - 1
                        end
                        output = output:sub(1, length) .. notice
                        pa.log("tool.result.truncated")
                    end
                    local tokens = model:tokens(output)
                    if tokens > available then
                        output = string.format(
                            "run_lua result omitted: quota exhausted (call #%d, original %d bytes)",
                            admission.row.id,
                            original_bytes
                        )
                        tokens = 0
                        pa.log("tool.result.quota")
                    else
                        available = available - tokens
                    end
                    outputs[index] = output
                    result_events[#result_events + 1] = { kind = "result", text = output, tokens = tokens }
                else
                    outputs[index] = "quota exhausted"
                end
            end
            if #result_events > 0 then
                store:append(call.branch, result_events)
            end
            for _, output in ipairs(outputs) do
                pa.emit(fenced("text", output))
            end
            local remaining = store:quota(call.run)
            for index, tool in ipairs(completion.calls) do
                local content = outputs[index]
                if index == #completion.calls then
                    content = content .. "\nquota_remaining=" .. remaining
                end
                messages[#messages + 1] = { role = "tool", tool_call_id = tool.id, content = content }
            end
        end
        error("model round limit exhausted", 0)
    end

    local function run(start, config)
        pa.log("store.open.begin")
        local store = make_store(spec.store)
        pa.log("store.open.end")
        local model = make_model(spec.model, config.models)
        local memory
        local result = table.pack(pcall(function()
            local call = start(store)
            pa.log("branch." .. call.branch)
            if pa.profile then
                pa.log("memory.open.begin")
            end
            memory = make_memory({
                cygnet = spec.cygnet,
                chronological = config.retrieval.chronological,
                semantic = config.retrieval.semantic,
            }, store, model)
            if pa.profile then
                pa.log("memory.open.end")
            end
            return call, execute(store, memory, model, call)
        end))
        local memory_closed = not memory or pcall(memory.close, memory)
        local completed, complete_problem = true, nil
        if result[1] and memory_closed and not result[2].temporary then
            pa.log("store.finish.begin")
            completed, complete_problem = pcall(store.finish, store, result[2].branch, result[3].id)
            pa.log("store.finish.end")
        end
        local store_closed, store_problem = pcall(store.close, store)
        if not result[1] then
            pa.log("run.failed")
            error(result[2], 0)
        end
        assert(memory_closed, "failed to close memory")
        if not completed then
            error(complete_problem, 0)
        end
        if not store_closed then
            error(store_problem, 0)
        end
        return result[2], result[3]
    end

    function runner:root(call)
        return run(function(store)
            if call.automatic then
                call.parent = store:head(call.actor)
                call.memory = call.parent or 0
            end
            local run_id, branch, start =
                store:start(call.actor, call.quota, call.parent, call.memory, call.preset_name, call.question)
            call.run, call.branch, call.start = run_id, branch, start.id
            return call
        end, call.config)
    end

    function runner:nested(config, caller, request)
        return run(function(store)
            local context = store:caller(config.actor, caller)
            local preset = request.preset or context.preset
            local available = false
            for _, target in ipairs(spec.presets[context.preset].targets) do
                available = available or target == preset
            end
            assert(available, "Zinc preset is unavailable")
            local branch = store:child(context.run, request.parent, request.memory, preset, request.question)
            return {
                actor = config.actor,
                branch = branch,
                config = config,
                temporary = true,
                memory = request.memory,
                parent = request.parent,
                preset = spec.presets[preset],
                preset_name = preset,
                question = request.question,
                run = context.run,
            }
        end, config)
    end

    local function access(work)
        local store = make_store(spec.store)
        local result = table.pack(pcall(work, store))
        local closed, problem = pcall(store.close, store)
        if not result[1] then
            error(result[2], 0)
        end
        if not closed then
            error(problem, 0)
        end
        return table.unpack(result, 2, result.n)
    end

    function runner:destroy(actor, caller, branch)
        return access(function(store)
            local context = store:caller(actor, caller)
            store:destroy(actor, context.branch, branch)
            return "destroyed"
        end)
    end

    return runner
end
