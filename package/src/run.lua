local encode_json = require("lunajson.encoder")()
local make_memory = require("src.memory")
local make_store = require("src.store")
local pa = require("pa")

local CORE_ADAPTER = [[
callable(self,function(_,request) return invoke("zinc_call","call",request) end)
self.destroy=function(branch) return invoke("zinc_destroy","destroy",branch) end
]]
local NESTED_CALL = [[self({text=Q,parent=P,through=M,preset=S}) -> {branch,event,parent,through,text}
Q: nonempty string; P: parent event id or 0 (current %s)
M: inclusive history event id or 0 (current %d)
S: optional preset; nil keeps the current preset; allowed: %s
self.destroy(temporary_branch) -> "destroyed"]]

local function names(value)
    local result = {}
    for name in pairs(value) do
        result[#result + 1] = name
    end
    table.sort(result)
    return result
end

local function render(name, preset, documents, tools)
    local lines = {
        documents.base,
        documents.presets[name],
    }
    if name == "configured" then
        lines[#lines + 1] = "Roots"
        for _, root in ipairs(names(tools.roots)) do
            lines[#lines + 1] = root .. " = " .. tools.roots[root] .. " [read, write, search]"
        end
        lines[#lines + 1] = "HTTP"
        for _, action in ipairs(names(tools.actions)) do
            local selected = tools.actions[action]
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
            "\nreturn self,{text=%q,parent=%s,through=%d}\nend)((...),callable)\ncallable=nil\n",
            call.question,
            call.parent and tostring(call.parent) or "0",
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
    local runner = {}

    local function execute(store, memory, model, call)
        local selected = render(call.preset_name, call.preset, documents, call.config.tools)
        local imports = import_prompt()
        local parent = call.parent and tostring(call.parent) or "0"
        local system = selected.system
            .. (imports ~= "" and "\n" .. imports or "")
            .. "\n"
            .. string.format(NESTED_CALL, parent, call.memory, selected.targets)
        pa.log("memory.context.begin")
        local context = memory:context(call.actor, call.memory, call.branch, call.question, call.run)
        pa.log("memory.context.end")
        system = system
            .. "\nModel quota remaining: "
            .. store:quota(call.run)
            .. " reported tokens. Requests stop when this reaches zero."
        local user = call.question
        if call.memory ~= 0 then
            user = "History:\n" .. context .. "\n\nQuestion:\n" .. user
        end
        local user_content = user
        if call.images then
            user_content = { { type = "text", text = user } }
            for _, image in ipairs(call.images) do
                user_content[#user_content + 1] = {
                    type = "image_url",
                    image_url = { url = "data:" .. image.type .. ";base64," .. image.data },
                }
            end
        end
        local messages = { { role = "system", content = system }, { role = "user", content = user_content } }
        for _ = 1, call.config.run.rounds do
            assert(store:quota(call.run) > 0, "model quota exhausted")
            pa.log("model.chat.begin")
            local completion = model:chat(messages, call.branch)
            if completion.usage then
                store:charge(call.run, completion.usage)
            end
            pa.log("model.chat.end")
            assert(not completion.truncated, "chat completion was truncated; lower context or raise the output limit")
            assert(not completion.error, completion.error)
            local tool_calls = #completion.calls > 0 and completion.tool_calls or nil
            local events = {}
            if completion.reasoning and completion.reasoning ~= "" then
                events[#events + 1] = { kind = "reasoning", text = completion.reasoning }
            end
            if completion.content and completion.content ~= "" then
                events[#events + 1] = { kind = "response", text = completion.content }
            end
            local rows = #events > 0 and store:append(call.branch, events) or {}
            local previous = messages[#messages]
            if previous.role == "assistant" and previous.content == "" and not previous.tool_calls then
                previous.reasoning_content = (previous.reasoning_content or "") .. (completion.reasoning or "")
                previous.content = completion.content or ""
                previous.tool_calls = tool_calls
            else
                messages[#messages + 1] = {
                    role = "assistant",
                    reasoning_content = completion.reasoning,
                    content = completion.content or "",
                    tool_calls = tool_calls,
                }
            end
            pa.emit(encode_json({
                type = "turn",
                branch = call.branch,
                final = #completion.calls == 0 and completion.content ~= nil,
            }))
            if #completion.calls == 0 then
                if completion.content then
                    return assert(rows[#rows], "model returned no response")
                end
            else
                local requests = {}
                for index, tool in ipairs(completion.calls) do
                    requests[index] = { kind = "call", text = tool.code }
                end
                local admitted = store:append(call.branch, requests)
                local sources = {}
                for index, tool in ipairs(completion.calls) do
                    pa.emit(
                        encode_json({ type = "tool", branch = call.branch, call = admitted[index].id, code = tool.code })
                    )
                    sources[index] = source(selected, admitted[index].id, call, tool.code)
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
                    evaluated = pa.eval(view, sources, "")
                    if pa.profile then
                        pa.log("tool.eval.end")
                    end
                else
                    evaluated = {}
                end

                local outputs, result_events = {}, {}
                for index in ipairs(completion.calls) do
                    local result = evaluated[index]
                    local output = result[1] and result[2] or "run_lua failed:\n" .. result[2]
                    if not result[1] then
                        pa.log("tool.eval.failed")
                    end
                    if output == "" or not utf8.len(output) then
                        output = "run_lua failed: invalid result"
                    end
                    local original_bytes = #output
                    local limit = call.config.run.tool_bytes
                    if original_bytes > limit then
                        local notice = string.format(
                            "\n[result truncated: call #%d, original %d bytes]",
                            admitted[index].id,
                            original_bytes
                        )
                        local length = limit - #notice
                        while length > 0 and not utf8.len(output:sub(1, length)) do
                            length = length - 1
                        end
                        output = output:sub(1, length) .. notice
                        pa.log("tool.result.truncated")
                    end
                    outputs[index] = output
                    result_events[index] = { kind = "result", text = output }
                end
                store:append(call.branch, result_events)
                for index, output in ipairs(outputs) do
                    pa.emit(encode_json({
                        type = "tool_result",
                        branch = call.branch,
                        call = admitted[index].id,
                        ok = evaluated[index][1],
                        text = output,
                    }))
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
        end
        error("model round limit exhausted", 0)
    end

    local function run(start, config)
        pa.log("store.open.begin")
        local store = make_store({ path = config.store })
        pa.log("store.open.end")
        local model = make_model(config)
        local memory
        local result = table.pack(xpcall(function()
            local call = start(store)
            pa.log("branch." .. call.branch)
            pa.emit(encode_json({ type = "start", branch = call.branch, root = not call.temporary }))
            if pa.profile then
                pa.log("memory.open.begin")
            end
            memory = make_memory({
                cygnet = config.cygnet,
                chronological = config.history,
                semantic = config.search,
            }, store, model)
            if pa.profile then
                pa.log("memory.open.end")
            end
            return call, execute(store, memory, model, call)
        end, debug.traceback))
        local memory_closed, memory_problem = true, nil
        if memory then
            memory_closed, memory_problem = pcall(memory.close, memory)
        end
        local completed, complete_problem = true, nil
        if result[1] and memory_closed and not result[2].temporary then
            pa.log("store.finish.begin")
            completed, complete_problem = pcall(store.finish, store, result[2].branch, result[3].id)
            pa.log("store.finish.end")
        end
        local usage
        if result[1] then
            local _
            _, usage = store:quota(result[2].run)
        end
        local store_closed, store_problem = pcall(store.close, store)
        if not result[1] then
            pa.log("run.failed")
            error(result[2], 0)
        end
        if not memory_closed then
            error(memory_problem, 0)
        end
        if not completed then
            error(complete_problem, 0)
        end
        if not store_closed then
            error(store_problem, 0)
        end
        return result[2], result[3], usage
    end

    function runner:root(call)
        return run(function(store)
            local run_id, branch, start = store:start(
                call.actor,
                call.quota,
                call.parent,
                call.memory,
                call.preset_name,
                call.question,
                call.automatic
            )
            call.run, call.branch, call.start = run_id, branch, start.id
            call.parent, call.memory = start.parent, start.memory
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

    local function access(config, work)
        local store = make_store({ path = config.store })
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

    function runner:destroy(config, caller, branch)
        return access(config, function(store)
            local context = store:caller(config.actor, caller)
            store:destroy(config.actor, context.branch, branch)
            return "destroyed"
        end)
    end

    return runner
end
