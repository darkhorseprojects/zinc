local make_memory = require("src.memory")
local make_store = require("src.store")
local pa = require("pa")

local CORE_ADAPTER = [[
self=setmetatable(self,{
 __call=function(_,request) return invoke("zinc_call","call",request) end,
 __metatable=false,
})
self.destroy=function(branch) return invoke("zinc_destroy","destroy",branch) end
]]

local function names(value)
    local result = {}
    for name in pairs(value) do
        result[#result + 1] = name
    end
    table.sort(result)
    return result
end

local function render(name, preset, documents)
    local lines = {
        documents.base,
        documents.presets[name],
        "`self` and `input` are defined. Do not redefine them. Every source must end with a value-returning `return` statement. Never use `print`.",
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
    local members, adapters = names(preset.members), { CORE_ADAPTER }
    for _, member in ipairs(members) do
        local descriptor = preset.members[member]
        for _, usage in ipairs(descriptor.usage) do
            lines[#lines + 1] = usage
        end
        adapters[#adapters + 1] = descriptor.adapter
    end
    return { system = table.concat(lines, "\n"), names = members, adapters = adapters, prompt = preset.prompt }
end

local function import_prompt(imports)
    local selected, lines = names(imports), {}
    if #selected > 0 then
        lines[1] = "Imports"
        for _, name in ipairs(selected) do
            lines[#lines + 1] = string.format("self.agents[%q].call(request) -> result; %s", name, imports[name])
        end
    end
    return selected, table.concat(lines, "\n")
end

local function source(prepared, imports, caller, call, code)
    local adapters = table.concat(prepared.adapters, "\n")
    local agents = { "self.agents={}" }
    for _, name in ipairs(imports) do
        agents[#agents + 1] = string.format(
            'self.agents[%q]={call=function(request) return invoke("agent","call",%q,request) end}',
            name,
            name
        )
    end
    return "local self,input=(function(raw,_,setmetatable)\nlocal caller="
        .. caller
        .. "\n"
        .. [[local function invoke(member,action,...)
 return raw[member]({caller=caller,action=action,arguments={...}})
end
local self={}
]]
        .. adapters
        .. "\n"
        .. table.concat(agents, "\n")
        .. string.format(
            "\nreturn self,{question=%q,parent=%s,memory=%d}\nend)((...),select(2,...),setmetatable)\nsetmetatable=nil\n",
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

return function(spec, entry, model, documents)
    local prepared = {}
    for name, preset in pairs(spec.presets) do
        prepared[preset] = render(name, preset, documents)
    end

    local runner = {}

    local function execute(store, memory, call)
        local selected = prepared[call.preset]
        local import_names, imports = import_prompt(call.imports)
        local system = selected.system
            .. (imports ~= "" and "\n" .. imports or "")
            .. "\n"
            .. selected.prompt(call.parent, call.memory)
            .. "\nEval quota: "
            .. store:quota(call.run)
            .. " tokens. Source and result tokens are charged."
        local context = memory:context(call.actor, call.memory, call.branch, call.question)
        local user = call.question
        if call.memory ~= 0 then
            user = "History:\n" .. context .. "\n\nQuestion:\n" .. user
        end
        local messages = { { role = "system", content = system }, { role = "user", content = user } }

        for _ = 1, spec.limits.model_rounds do
            local completion = model:chat(messages)
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
            local sources, positions = {}, {}
            for index, admission in ipairs(admitted) do
                if admission.accepted then
                    positions[index] = #sources + 1
                    sources[#sources + 1] =
                        source(selected, import_names, admission.row.id, call, completion.calls[index].code)
                end
            end

            local evaluated
            if #sources > 0 then
                local ok, value = pcall(
                    pa.eval,
                    (function()
                        local view = {
                            zinc_call = entry.zinc_call,
                            zinc_destroy = entry.zinc_destroy,
                        }
                        if #import_names > 0 then
                            view.agent = entry.agent
                        end
                        for _, name in ipairs(selected.names) do
                            view[name] = entry[name]
                        end
                        return view
                    end)(),
                    sources,
                    ""
                )
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
            for index in ipairs(completion.calls) do
                local position = positions[index]
                if position then
                    local result = evaluated[position]
                    local output
                    if type(result) == "table" and type(result[1]) == "boolean" and type(result[2]) == "string" then
                        output = result[1] and result[2] or "run_lua failed:\n" .. result[2]
                    else
                        output = "run_lua failed: invalid Eval result"
                    end
                    if output == "" or not utf8.len(output) then
                        output = "run_lua failed: invalid result"
                    end
                    outputs[index] = output
                    result_events[#result_events + 1] = {
                        kind = "result",
                        text = output,
                        tokens = model:tokens(output),
                    }
                else
                    outputs[index] = "quota exhausted"
                end
            end
            if #result_events > 0 then
                store:append(call.branch, result_events)
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

    local function run(start)
        local store = make_store(spec.store)
        local memory
        local result = table.pack(pcall(function()
            local call = start(store)
            memory = make_memory(spec.memory, store, model)
            return call, execute(store, memory, call)
        end))
        local memory_closed = not memory or pcall(memory.close, memory)
        local store_closed, store_problem = pcall(store.close, store)
        if not result[1] then
            error(result[2], 0)
        end
        assert(memory_closed, "failed to close memory")
        if not store_closed then
            error(store_problem, 0)
        end
        return result[2], result[3]
    end

    function runner:root(call)
        return run(function(store)
            local run_id, branch =
                store:start(call.actor, call.quota, call.parent, call.memory, call.preset_name, call.question)
            call.run, call.branch = run_id, branch
            return call
        end)
    end

    function runner:nested(actor, imports, caller, request)
        return run(function(store)
            local context = store:caller(actor, caller)
            local preset = request.preset or context.preset
            local available = false
            for _, target in ipairs(spec.presets[context.preset].targets) do
                available = available or target == preset
            end
            assert(available, "Zinc preset is unavailable")
            local branch = store:child(context.run, request.parent, request.memory, preset, request.question)
            return {
                actor = actor,
                branch = branch,
                imports = imports,
                memory = request.memory,
                parent = request.parent,
                preset = spec.presets[preset],
                preset_name = preset,
                question = request.question,
                run = context.run,
            }
        end)
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

    function runner:authorize(actor, caller)
        return access(function(store)
            return store:caller(actor, caller)
        end)
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
