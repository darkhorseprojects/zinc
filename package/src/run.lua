local decode_json = require("lunajson.decoder")()
local encode_json = require("lunajson.encoder")()
local make_model = require("src.model")
local make_memory = require("src.memory")
local make_store = require("src.store")
local pa = require("pa")

local NULL = {}

local function decode(source, maximum)
    assert(type(source) == "string" and (not maximum or #source <= maximum) and utf8.len(source), "invalid JSON bytes")
    local value, offset = decode_json(source, 1, NULL)
    assert(source:sub(offset):match("^[ \t\r\n]*$"), "JSON has trailing data")
    return value
end

local function object(source, maximum)
    local value = decode(source, maximum)
    assert(source:match("^[ \t\r\n]*{"), "JSON value must be an object")
    return value
end

local function merge(schema, values, path, partial, parameters)
    assert(type(values) == "table" and values ~= NULL, "invalid " .. path)
    for name in pairs(values) do
        assert(schema[name], "unknown " .. path .. " field: " .. tostring(name))
    end
    local output = {}
    for name, rule in pairs(schema) do
        local field = path .. "." .. name
        local selected = values[name]
        if rule.type then
            if selected == nil then
                selected = rule.default
            end
            if selected ~= nil or not (partial or rule.optional) then
                if rule.type == "integer" then
                    assert(
                        math.type(selected) == "integer"
                            and (rule.minimum == nil or selected >= rule.minimum)
                            and (rule.default == nil or selected <= rule.default),
                        "invalid " .. field
                    )
                else
                    assert(type(selected) == rule.type and selected ~= NULL, "invalid " .. field)
                    if rule.type == "number" then
                        assert(selected == selected and math.abs(selected) < math.huge, "invalid " .. field)
                    elseif rule.type == "string" then
                        assert(selected ~= "" and utf8.len(selected), "invalid " .. field)
                    end
                end
            end
            output[name] = selected
            if parameters and rule.description then
                parameters[#parameters + 1] = {
                    name = field:gsub("^config%.", ""):gsub("%.", "_"),
                    path = field,
                    type = rule.type,
                    description = rule.description,
                    minimum = rule.minimum,
                    maximum = rule.type == "integer" and selected or nil,
                    autocomplete = rule.autocomplete,
                }
            end
        else
            output[name] = merge(rule, selected == nil and {} or selected, field, partial, parameters)
        end
    end
    return output
end

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

local function render(name, preset, document, tools)
    local lines = {
        document,
        tostring(preset),
    }
    if name == "configured" then
        lines[#lines + 1] = "Roots"
        for _, root in ipairs(names(tools.roots)) do
            lines[#lines + 1] = root
                .. " = "
                .. tools.roots[root]
                .. " [read, write"
                .. (tools.search and ", search" or "")
                .. "]"
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
    local members, adapters = names(preset), { CORE_ADAPTER }
    for _, member in ipairs(members) do
        local operations = {}
        for action, fn in pairs(preset[member]) do
            if type(fn) == "function" then
                operations[#operations + 1] = action
            end
        end
        table.sort(operations)
        adapters[#adapters + 1] = "self." .. member .. "={}"
        for _, action in ipairs(operations) do
            local parameters = {}
            for index = 1, debug.getinfo(preset[member][action], "u").nparams - 1 do
                parameters[index] = "arg" .. index
            end
            local arguments = table.concat(parameters, ",")
            adapters[#adapters + 1] = string.format(
                "self.%s.%s=function(%s) return invoke(%q,%q%s) end",
                member,
                action,
                arguments,
                member,
                action,
                arguments ~= "" and "," .. arguments or ""
            )
        end
    end
    local targets = { "nil" }
    for _, target in ipairs(getmetatable(preset).targets) do
        targets[#targets + 1] = string.format("%q", target)
    end
    return {
        system = table.concat(lines, "\n"),
        names = members,
        adapters = table.concat(adapters, "\n"),
        targets = table.concat(targets, " | "),
    }
end

local function import_prompt()
    local selected, lines = pa.imports(), {}
    table.sort(selected)
    if #selected > 0 then
        lines[1] = "Imports"
        for _, name in ipairs(selected) do
            local document = tostring(require(name))
            assert(document ~= "", "invalid Import document")
            lines[#lines + 1] = document
        end
    end
    return table.concat(lines, "\n")
end

local function source(prepared, caller, call, code)
    return "local self,input=(function(raw,text,callable)\nlocal caller="
        .. caller
        .. string.format("\nlocal preset=%q\n", call.preset_name)
        .. [[local function invoke(member,action,...)
 return raw[member]({caller=caller,preset=preset,action=action,arguments=table.pack(...)})
end
local self={}
]]
        .. prepared.adapters
        .. string.format(
            "\nreturn self,{text=text,parent=%s,through=%d}\nend)((...),select(2,...),callable)\ncallable=nil\n",
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

return function(spec)
    local document = tostring(spec.document)
    local cached_source, cached_config

    local function request(value, nested)
        value = merge(spec.input, value, "input")
        assert(#value.text <= spec.limits.question_bytes, "Zinc text is too large")
        assert(nested or value.preset == nil, "preset is private")
        assert(not nested or value.images == nil, "nested calls cannot supply images")
        assert(not nested or value.parent ~= nil and value.through ~= nil, "nested calls require parent and through")
        value.automatic = value.parent == nil
        if value.parent == 0 then
            value.parent = nil
        end
        return value
    end

    local function configuration(opaque)
        if cached_config and opaque == cached_source then
            return cached_config
        end
        local value = merge(spec.config, object(opaque, spec.limits.config_bytes), "config")
        assert(spec.presets[value.preset], "unknown Zinc preset")
        assert(next(value.providers), "providers are required")
        for name, provider in pairs(value.providers) do
            assert(name == "llama" or name == "openrouter", "unsupported model provider: " .. tostring(name))
            assert(type(provider) == "table" and type(provider.url) == "string", "invalid provider: " .. name)
            assert(provider.url:match("^https?://[^/%s?#]+$"), "provider URL must be an HTTP origin")
            assert(
                provider.token == nil or type(provider.token) == "string" and provider.token ~= "",
                "invalid provider token"
            )
            for key in pairs(provider) do
                assert(key == "url" or key == "token", "unknown provider field: " .. tostring(key))
            end
        end
        assert(value.limits.rerank.pair_bytes > value.limits.rerank.query_bytes, "invalid rerank limits")
        local tools = value.tools or {}
        assert(type(tools) == "table" and tools ~= NULL, "invalid tools")
        for key in pairs(tools) do
            assert(key == "roots" or key == "actions" or key == "search", "unknown tools field: " .. tostring(key))
        end
        tools.roots, tools.actions = tools.roots or {}, tools.actions or {}
        assert(type(tools.roots) == "table" and type(tools.actions) == "table", "invalid tool grants")
        for name, path in pairs(tools.roots) do
            assert(type(name) == "string" and type(path) == "string" and path ~= "", "invalid tool root")
        end
        for name, action in pairs(tools.actions) do
            assert(type(name) == "string" and type(action) == "table", "invalid HTTP action")
            for key in pairs(action) do
                assert(key == "method" or key == "origin" or key == "path", "unknown HTTP action field")
            end
            assert(
                type(action.method) == "string" and type(action.origin) == "string" and type(action.path) == "string",
                "invalid HTTP action"
            )
        end
        assert(
            tools.search == nil or type(tools.search) == "string" and tools.search ~= "",
            "invalid search executable"
        )
        value.tools = tools
        cached_source, cached_config = opaque, value
        return value
    end

    local entry = {}

    local function execute(store, memory, model, config, call)
        local selected = render(call.preset_name, spec.presets[call.preset_name], document, config.tools)
        local view = { zinc_call = entry.zinc_call, zinc_destroy = entry.zinc_destroy }
        for _, name in ipairs(selected.names) do
            view[name] = entry[name]
        end
        local imports = import_prompt()
        local parent = call.parent and tostring(call.parent) or "0"
        local system = selected.system
            .. (imports ~= "" and "\n" .. imports or "")
            .. "\n"
            .. string.format(NESTED_CALL, parent, call.memory, selected.targets)
        pa.log("memory.context.begin")
        local context = memory:context(config.actor, call.memory, call.branch, call.text, call.run, call.id)
        pa.log("memory.context.end")
        system = system
            .. "\nModel quota remaining: "
            .. store:quota(call.run)
            .. " reported tokens. Requests stop when this reaches zero."
        local user = call.text
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
        for _ = 1, config.run.rounds do
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
            messages[#messages + 1] = {
                role = "assistant",
                reasoning_content = completion.reasoning,
                content = completion.content or "",
                tool_calls = tool_calls,
            }
            pa.emit(encode_json({
                type = "turn",
                branch = call.branch,
                final = #completion.calls == 0 and completion.content ~= nil,
            }))
            if #completion.calls == 0 then
                return assert(rows[#rows], "model returned no response")
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

                if pa.profile then
                    pa.log("tool.eval.begin")
                end
                local evaluated = pa.eval(view, sources, call.text)
                if pa.profile then
                    pa.log("tool.eval.end")
                end

                local result_events = {}
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
                    local limit = config.run.tool_bytes
                    if original_bytes > limit then
                        local notice = string.format(
                            "\n[result truncated: call #%d, original %d bytes]",
                            admitted[index].id,
                            original_bytes
                        )
                        local length = limit - #notice
                        length = utf8.offset(output, 0, length + 1) - 1
                        output = output:sub(1, length) .. notice
                        pa.log("tool.result.truncated")
                    end
                    result_events[index] = { kind = "result", text = output }
                end
                store:append(call.branch, result_events)
                local remaining = store:quota(call.run)
                for index, tool in ipairs(completion.calls) do
                    local content = result_events[index].text
                    pa.emit(encode_json({
                        type = "tool_result",
                        branch = call.branch,
                        call = admitted[index].id,
                        ok = evaluated[index][1],
                        text = content,
                    }))
                    if index == #completion.calls then
                        content = content .. "\nquota_remaining=" .. remaining
                    end
                    messages[#messages + 1] = { role = "tool", tool_call_id = tool.id, content = content }
                end
            end
        end
        error("model round limit exhausted", 0)
    end

    local function run(config, value, caller)
        pa.log("store.open.begin")
        local store <close> = make_store({ path = config.store })
        pa.log("store.open.end")
        local model = make_model(config)
        local preset, run_id, _, start = config.preset
        if caller then
            local context = store:caller(config.actor, caller)
            preset = value.preset or context.preset
            local available = false
            for _, target in ipairs(getmetatable(spec.presets[context.preset]).targets) do
                available = available or target == preset
            end
            assert(available, "Zinc preset is unavailable")
            run_id = context.run
            _, start = store:child(run_id, value.parent, value.through, preset, value.text)
        else
            run_id, _, start = store:start(
                config.actor,
                config.run.tokens,
                value.parent,
                value.through,
                preset,
                value.text,
                value.automatic
            )
        end
        start.run, start.preset_name, start.temporary, start.images = run_id, preset, caller ~= nil, value.images
        local call = start
        pa.log("branch." .. call.branch)
        pa.emit(encode_json({ type = "start", branch = call.branch, root = not call.temporary }))
        local memory <close> = make_memory({
            cygnet = config.cygnet,
            chronological = config.history,
            semantic = config.search,
        }, store, model)
        local final = execute(store, memory, model, config, call)
        if not call.temporary then
            pa.log("store.finish.begin")
            store:finish(call.branch, final.id)
            pa.log("store.finish.end")
        end
        local _, usage = store:quota(call.run)
        return call, final, usage
    end

    function entry.describe(input, opaque)
        assert(input == "", "describe takes empty input")
        local parameters = {}
        merge(spec.config, object(opaque, spec.limits.config_bytes), "config", true, parameters)
        merge(spec.input, {}, "input", true, parameters)
        table.sort(parameters, function(a, b)
            return a.name < b.name
        end)
        return encode_json({ input = "json", output = "json", parameters = parameters })
    end

    function entry.models(input, opaque)
        assert(input == "chat" or input == "rerank", "models takes chat or rerank")
        return encode_json(make_model(configuration(opaque)):models(input))
    end

    function entry.document(input, opaque)
        configuration(opaque)
        assert(input == "", "document takes empty input")
        return document
    end

    function entry.design(input, opaque)
        configuration(opaque)
        assert(input == "", "design takes empty input")
        return tostring(spec.design)
    end

    for _, preset in pairs(spec.presets) do
        for member in pairs(preset) do
            if not entry[member] then
                entry[member] = function(value, opaque)
                    local config = configuration(opaque)
                    assert(
                        type(value) == "table" and type(value.action) == "string" and type(value.arguments) == "table",
                        "invalid capability call"
                    )
                    local selected_preset = assert(spec.presets[value.preset], "invalid capability preset")
                    local selected = assert(selected_preset[member], member .. " is unavailable")
                    return selected(value, config.tools)
                end
            end
        end
    end

    function entry.zinc_call(value, opaque)
        local config = configuration(opaque)
        assert(type(value) == "table" and math.type(value.caller) == "integer", "invalid Zinc caller")
        local call, final = run(config, request(value.arguments[1], true), value.caller)
        return {
            branch = call.branch,
            event = final.id,
            parent = final.parent,
            through = final.memory,
            text = final.text,
        }
    end

    function entry.zinc_destroy(value, opaque)
        local config = configuration(opaque)
        assert(type(value) == "table" and math.type(value.caller) == "integer", "invalid Zinc caller")
        local branch = value.arguments and value.arguments[1]
        assert(math.type(branch) == "integer" and branch > 0, "invalid branch")
        local store <close> = make_store({ path = config.store })
        local context = store:caller(config.actor, value.caller)
        store:destroy(config.actor, context.branch, branch)
        return "destroyed"
    end

    local function invoke(input, opaque)
        local value = request(object(input, spec.limits.request_bytes), false)
        if value.images then
            assert(type(value.images) == "table" and value.images ~= NULL and #value.images <= 4, "invalid image count")
            for key, image in pairs(value.images) do
                assert(math.type(key) == "integer" and key >= 1 and key <= #value.images, "invalid image array")
                assert(
                    type(image) == "table"
                        and (image.type == "image/png" or image.type == "image/jpeg" or image.type == "image/webp"),
                    "invalid image type"
                )
                assert(type(image.data) == "string" and image.data:match("^[A-Za-z0-9+/]+=?=?$"), "invalid image data")
                for name in pairs(image) do
                    assert(name == "type" or name == "data", "unknown image field")
                end
            end
            if #value.images == 0 then
                value.images = nil
            end
        end
        local call, final, usage = run(configuration(opaque), value)
        return encode_json({
            text = final.text,
            run = call.run,
            branch = call.branch,
            event = final.id,
            parent = final.parent or 0,
            through = final.memory,
            usage = { total_tokens = usage },
        })
    end

    return setmetatable(entry, {
        __call = function(_, input, opaque)
            return invoke(input, opaque)
        end,
        __metatable = false,
    })
end
