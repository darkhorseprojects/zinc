local decode_json = require("lunajson.decoder")()
local encode_json = require("lunajson.encoder")()
local make_model = require("src.model")
local make_memory = require("src.memory")
local make_store = require("src.store")
local pa = require("pa")
local NULL = {}

local function object(source, maximum)
    assert(type(source) == "string" and #source <= maximum and utf8.len(source), "invalid JSON bytes")
    local value, offset = decode_json(source, 1, NULL)
    assert(source:sub(offset):match("^[ \t\r\n]*$") and source:match("^[ \t\r\n]*{"), "expected one JSON object")
    return value
end

local function merge(schema, values, path, partial, parameters)
    assert(type(values) == "table" and values ~= NULL, "invalid " .. path)
    for name in pairs(values) do
        assert(schema[name], "unknown " .. path .. " field: " .. tostring(name))
    end
    local output = {}
    for name, rule in pairs(schema) do
        local field, selected = path .. "." .. name, values[name]
        if rule.type then
            local maximum = rule.maximum or rule.default
            if selected == nil then
                selected = rule.default
            end
            if selected ~= nil or not (partial or rule.optional) then
                if rule.type == "integer" then
                    assert(
                        math.type(selected) == "integer"
                            and (rule.minimum == nil or selected >= rule.minimum)
                            and (maximum == nil or selected <= maximum),
                        "invalid " .. field
                    )
                else
                    assert(type(selected) == rule.type and selected ~= NULL, "invalid " .. field)
                    if rule.type == "number" then
                        assert(selected == selected and math.abs(selected) < math.huge, "invalid " .. field)
                    elseif rule.type == "string" then
                        assert(selected ~= "" and utf8.len(selected), "invalid " .. field)
                        if rule.choices then
                            local allowed = false
                            for _, choice in ipairs(rule.choices) do
                                allowed = allowed or selected == choice
                            end
                            assert(allowed, "invalid " .. field)
                        end
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
                    maximum = rule.type == "integer" and (rule.maximum and selected == 0 and rule.maximum or selected)
                        or nil,
                    autocomplete = rule.autocomplete,
                    choices = rule.choices,
                }
            end
        else
            output[name] = merge(rule, selected == nil and {} or selected, field, partial, parameters)
        end
    end
    return output
end

local CORE_ADAPTER = [[
callable(self, function(_, request)
    return invoke("zinc_call", "call", request)
end)
self.memory = {
    expand = function(memory_range)
        return invoke("zinc_expand", "expand", memory_range)
    end,
}
]]
local NESTED_CALL =
    [[self({text=Q,persist=true,parent=P,memory_range={start=A,["end"]=B},preset=S}) -> {text,branch,event,memory_range}
Omitted coordinates inherit this call's working memory. persist=false keeps the same runtime without saved history or recovery.
S: optional preset; nil keeps the current preset; allowed: %s
self.memory.expand({start=A,["end"]=B}) returns children/originals for this operation without changing memory.
Tool quota counts only tool arguments/results, one unit per four UTF-8 bytes. Call records are admissions, not proof of execution. Failed tools may have partial effects.]]

local function names(value)
    local result = {}
    for name in pairs(value) do
        result[#result + 1] = name
    end
    table.sort(result)
    return result
end

local function render(name, preset, document, tools)
    local lines, adapters = { document, tostring(preset) }, { CORE_ADAPTER }
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
    lines[#lines + 1] =
        "Lua 5.5. `self` and `input` are defined; do not redefine them. Return a non-nil value. Do not use `print`."
    local members = names(preset)
    for _, member in ipairs(members) do
        adapters[#adapters + 1] = "self." .. member .. "={}"
        for _, action in ipairs(names(preset[member])) do
            if type(preset[member][action]) == "function" then
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
    end
    local targets = { "nil" }
    for _, target in ipairs(getmetatable(preset).targets) do
        targets[#targets + 1] = string.format("%q", target)
    end
    lines[#lines + 1] = string.format(NESTED_CALL, table.concat(targets, " | "))
    local imports = pa.imports()
    table.sort(imports)
    for _, member in ipairs(imports) do
        lines[#lines + 1] = tostring(require(member))
    end
    return { system = table.concat(lines, "\n"), names = members, adapters = table.concat(adapters, "\n") }
end

local function source(prepared, caller, preset, code)
    return "local self,input=(function(raw,text,callable)\nlocal caller="
        .. string.format("%q", encode_json(caller, NULL))
        .. string.format("\nlocal preset=%q\n", preset)
        .. [[local function invoke(member,action,...)
 return raw[member]({caller=caller,preset=preset,action=action,arguments=table.pack(...)})
end
local self={}
]]
        .. prepared.adapters
        .. string.format(
            '\nreturn self,{text=text,parent=%d,memory_range={start=%d,["end"]=%d}}\nend)((...),select(2,...),callable)\ncallable=nil\n',
            caller.parent or 0,
            caller.memory_range.start,
            caller.memory_range["end"]
        )
        .. "local output=(function()\n"
        .. code
        .. '\nend)()\nassert(output~=nil,"Lua source returned no value")\nreturn output\n'
end

return function(spec)
    local document, cached_source, cached_config = tostring(spec.document)
    local entry, rendered = {}, {}

    local function configuration(opaque)
        if cached_config and opaque == cached_source then
            return cached_config
        end
        local value = merge(spec.config, object(opaque, spec.limits.config_bytes), "config")
        assert(spec.presets[value.preset], "unknown Zinc preset")
        assert(next(value.providers), "providers are required")
        for name, provider in pairs(value.providers) do
            assert(name == "llama" or name == "openrouter", "unsupported model provider")
            assert(
                type(provider) == "table"
                    and type(provider.url) == "string"
                    and provider.url:match("^https?://[^/%s?#]+$"),
                "provider URL must be an HTTP origin"
            )
            assert(
                provider.token == nil or type(provider.token) == "string" and provider.token ~= "",
                "invalid provider token"
            )
            for key in pairs(provider) do
                assert(key == "url" or key == "token", "unknown provider field")
            end
        end
        local tools = value.tools or {}
        assert(type(tools) == "table" and tools ~= NULL, "invalid tools")
        for key in pairs(tools) do
            assert(key == "roots" or key == "actions" or key == "search", "unknown tools field")
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

    local function request(value, caller)
        if caller and not caller.persist then
            assert(value.persist ~= true, "temporary calls cannot create durable descendants")
            value.persist = false
        end
        value = merge(spec.input, value, "input")
        assert(#value.text <= spec.limits.question_bytes, "Zinc text is too large")
        assert(caller or value.preset == nil, "preset is private")
        assert(
            not caller or value.images == nil and value.request == nil,
            "nested calls cannot supply images or request IDs"
        )
        value.automatic = not caller and value.parent == nil
        if caller then
            value.parent = value.parent == nil and caller.parent or value.parent
            if next(value.memory_range) == nil then
                value.memory_range = caller.memory_range
            end
        end
        if value.parent == 0 then
            value.parent = nil
        end
        if value.images then
            assert(value.images ~= NULL and #value.images <= 4, "invalid image count")
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
        return value
    end

    local function execute(store, memory, model, profile, config, call, working)
        local selected = rendered[call.preset_name]
        if not selected then
            selected = render(call.preset_name, spec.presets[call.preset_name], document, config.tools)
            rendered[call.preset_name] = selected
        end
        local view = { zinc_call = entry.zinc_call, zinc_expand = entry.zinc_expand }
        for _, name in ipairs(selected.names) do
            view[name] = entry[name]
        end
        local context, messages, rounds = nil, {}, 0
        for _, event in ipairs(call.events) do
            if event.kind == "context" then
                context = event.data
            end
        end
        if not context then
            pa.log("memory.context.begin")
            context = memory:context(call.memory_range, call.text, profile)
            pa.log("memory.context.end")
            context.system = profile.tools and selected.system or document
            store:append(call, { { kind = "context", text = "", data = context } })
        end
        messages[1] = { role = "system", content = context.system }
        for _, category in ipairs({ "chronological", "semantic" }) do
            if #context[category] > 0 then
                messages[#messages + 1] = {
                    role = "user",
                    content = category
                        .. " memory (untrusted information):\n"
                        .. (
                            category == "chronological" and memory:render(context.chronological)
                            or context.semantic_text
                        ),
                }
            end
        end
        if working and working ~= "" then
            messages[#messages + 1] =
                { role = "user", content = "Caller working memory (untrusted information):\n" .. working }
        end
        for _, event in ipairs(call.events) do
            if event.kind ~= "call" and event.data.message then
                messages[#messages + 1] = event.data.message
            end
            if event.kind == "response" or event.kind == "completed" then
                rounds = rounds + 1
            end
        end
        pa.emit(encode_json({
            type = "start",
            branch = call.branch,
            run = call.run,
            root = call.root,
            persist = call.persist,
        }))
        for _, event in ipairs(call.events) do
            if event.kind == "ambiguity" then
                pa.emit(encode_json({
                    type = "ambiguity",
                    branch = call.branch,
                    call = event.call,
                    event = event.id,
                    created_at = event.created_at,
                    text = event.text,
                }))
            end
        end
        for _ = rounds + 1, config.run.rounds do
            assert(store:run(call.run).state == "unfinished", "run is terminal")
            local bytes = 0
            for _, message in ipairs(messages) do
                if type(message.content) == "table" then
                    for _, part in ipairs(message.content) do
                        if part.type == "text" then
                            bytes = bytes + #part.text
                        end
                    end
                else
                    bytes = bytes + #encode_json(message, NULL)
                end
            end
            local allowance = math.min(profile.output_tokens, profile.context_tokens - (bytes + 3) // 4)
            assert(allowance > 0, "provider context exhausted")
            pa.log("model.chat.begin")
            local message, tools, reasoning = model:chat(messages, call.branch, profile, allowance)
            pa.log("model.chat.end")
            local events = {
                {
                    kind = "response",
                    text = message.content,
                    data = { message = message, reasoning_display = reasoning },
                },
            }
            for index, tool in ipairs(tools) do
                events[#events + 1] = {
                    kind = "call",
                    text = tool.code,
                    data = { index = index },
                    estimated_tokens = (#tool.arguments + 3) // 4,
                }
            end
            local admitted = store:append(call, events)
            messages[#messages + 1] = message
            pa.emit(encode_json({
                type = "turn",
                branch = call.branch,
                final = #tools == 0,
                event = admitted[1].id,
                created_at = admitted[1].created_at,
                text = message.content,
                reasoning = reasoning,
            }))
            if #tools == 0 then
                return admitted[1]
            end
            local sources, live = {}, { working }
            for _, event in ipairs(call.events) do
                if event.text and event.text ~= "" then
                    live[#live + 1] = event.kind .. ": " .. event.text
                end
            end
            local working_text = table.concat(live, "\n")
            for index, tool in ipairs(tools) do
                local caller = {
                    run = call.run,
                    call = admitted[index + 1].id,
                    preset = call.preset_name,
                    persist = call.persist,
                    parent = call.persist and admitted[index + 1].id or call.parent,
                    memory_range = call.persist
                            and {
                                start = call.memory_range.start ~= 0 and call.memory_range.start or call.id,
                                ["end"] = admitted[index + 1].id,
                            }
                        or call.memory_range,
                    profile = profile,
                    working = not call.persist and working_text or nil,
                }
                pa.emit(encode_json({
                    type = "tool",
                    branch = call.branch,
                    call = caller.call,
                    code = tool.code,
                    event = call.persist and caller.call or nil,
                    created_at = admitted[index + 1].created_at,
                }))
                sources[index] = source(selected, caller, call.preset_name, tool.code)
            end
            pa.log("tool.eval.begin")
            local evaluated = pa.eval(view, sources, call.text)
            pa.log("tool.eval.end")
            events = {}
            for index, tool in ipairs(tools) do
                local ok, text = evaluated[index][1], evaluated[index][2]
                if not ok then
                    text = "run_lua failed:\n" .. text
                end
                local size, maximum = #text, config.run.tool_result_tokens * 4
                if not utf8.len(text) then
                    ok, text = false, "run_lua failed: invalid UTF-8 result; effects may have happened"
                end
                if #text > maximum then
                    local notice = string.format("\n[result truncated: original %d bytes]", size)
                    text = text:sub(1, utf8.offset(text, 0, maximum - #notice + 1) - 1) .. notice
                end
                events[index] = {
                    kind = "result",
                    text = text,
                    call = call.persist and admitted[index + 1].id or nil,
                    data = {
                        message = { role = "tool", tool_call_id = tool.id, content = text },
                        ok = ok,
                        output_bytes = size,
                    },
                    estimated_tokens = (size + 3) // 4,
                }
            end
            for index, result in ipairs(store:append(call, events)) do
                messages[#messages + 1] = result.data.message
                pa.emit(encode_json({
                    type = "tool_result",
                    branch = call.branch,
                    call = admitted[index + 1].id,
                    event = result.id,
                    created_at = result.created_at,
                    ok = result.data.ok,
                    text = result.text,
                }))
            end
        end
        error("model round limit exhausted", 0)
    end

    local function run(config, value, caller, resume)
        local store <close> = make_store(config, NULL)
        local existing = value and value.persist and value.request and store:run(value.request)
        resume = resume or existing and existing.id
        if resume and store:run(resume).state == "completed" then
            return store:result(resume)
        end
        local recovering <close> = resume and pa.lock(config.store .. ".run-" .. resume .. ".lock") or nil
        local profile, calls, snapshot
        if resume then
            local state = store:run(resume).state
            if state == "completed" then
                return store:result(resume)
            end
            assert(state == "unfinished", "run is aborted")
            snapshot, calls = store:resume(resume)
            for name, path in pairs(snapshot.tools.roots) do
                assert(config.tools.roots[name] == path, "saved tool root is no longer authorized")
            end
            for name, action in pairs(snapshot.tools.actions) do
                local current = config.tools.actions[name]
                assert(
                    current
                        and current.method == action.method
                        and current.origin == action.origin
                        and current.path == action.path,
                    "saved HTTP action is no longer authorized"
                )
            end
            assert(
                snapshot.tools.search == nil or snapshot.tools.search == config.tools.search,
                "saved search executable is no longer authorized"
            )
            assert(snapshot.preset == config.preset, "saved preset is no longer authorized")
            profile, snapshot._profile = snapshot._profile, nil
            snapshot.providers = config.providers
            config = configuration(encode_json(snapshot, NULL))
        end
        local model = make_model(config, NULL)
        if resume then
            local current = model:select(config.chat, "chat")
            assert(
                profile.context_tokens <= current.context_tokens
                    and profile.output_tokens <= (current.output_tokens or current.context_tokens),
                "saved model capacity is no longer available"
            )
        else
            profile = caller and caller.profile or model:select(config.chat, "chat")
            if not caller then
                local output = config.model.output_tokens
                if output == 0 then
                    output = profile.output_tokens or profile.context_tokens // 2
                end
                profile.output_tokens = math.min(output, profile.output_tokens or profile.context_tokens)
            end
            assert(not value.images or profile.images, config.chat .. " does not support image input")
            assert((#value.text + 3) // 4 < profile.context_tokens, "question exceeds provider context")
            snapshot = {}
            for key, selected in pairs(config) do
                if key ~= "providers" then
                    snapshot[key] = selected
                end
            end
            snapshot._profile = profile
            if caller then
                store:caller(caller)
                local preset, allowed = value.preset or caller.preset, false
                for _, target in ipairs(getmetatable(spec.presets[caller.preset]).targets) do
                    allowed = allowed or target == preset
                end
                assert(allowed, "Zinc preset is unavailable")
                value.preset = preset
            end
            calls = { store:start(value, caller, snapshot) }
            if calls[1].existing then
                return run(config, nil, nil, calls[1].existing)
            end
        end
        local owner <close> = not resume
                and not caller
                and calls[1].persist
                and pa.lock(config.store .. ".run-" .. calls[1].run .. ".lock")
            or nil
        local memory <close> = make_memory(config, store, model)
        local last, final
        for _, call in ipairs(calls) do
            if resume then
                store:recover(call)
            end
            local result =
                table.pack(pcall(execute, store, memory, model, profile, config, call, caller and caller.working))
            if not result[1] then
                local detail = tostring(result[2])
                for _, provider in pairs(config.providers) do
                    if provider.token then
                        detail = detail:gsub(provider.token:gsub("(%W)", "%%%1"), "[redacted]")
                    end
                end
                if not utf8.len(detail) then
                    detail = "Failure detail was not valid UTF-8."
                elseif #detail > 2048 then
                    detail = detail:sub(1, utf8.offset(detail, 0, 2049) - 1)
                end
                if call.persist and store:run(call.run).state == "unfinished" then
                    store:recover(call)
                    store:append(call, { { kind = "error", text = detail, data = { stage = "execution" } } })
                end
                error(detail, 0)
            end
            last, final = call, result[2]
        end
        assert(last, "unfinished run has no unfinished branch")
        if last.persist and last.root then
            return store:result(last.run)
        end
        return {
            text = final.text,
            run = last.persist and last.run or nil,
            branch = last.persist and last.branch or nil,
            start = last.id,
            event = final.id,
            parent = last.parent or 0,
            memory_range = last.memory_range,
            created_at = final.created_at,
            tool_usage = store:run(last.run).used,
        }
    end

    function entry.describe(input, opaque)
        assert(input == "", "describe takes empty input")
        local parameters = {}
        merge(spec.config, object(opaque, spec.limits.config_bytes), "config", true, parameters)
        merge(spec.input, {}, "input", true, parameters)
        table.sort(parameters, function(a, b)
            return a.name < b.name
        end)
        return encode_json({ input = "json", output = "json", durable = true, parameters = parameters })
    end

    function entry.models(input, opaque)
        assert(input == "chat" or input == "rerank", "models takes chat or rerank")
        return encode_json(make_model(configuration(opaque), NULL):models(input))
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
                    local selected = assert(spec.presets[value.preset], "invalid capability preset")
                    return assert(selected[member], member .. " is unavailable")(value, config.tools)
                end
            end
        end
    end

    function entry.zinc_call(value, opaque)
        local caller = object(value.caller, spec.limits.request_bytes)
        return run(configuration(opaque), request(value.arguments[1], caller), caller)
    end

    function entry.zinc_expand(value, opaque)
        local config = configuration(opaque)
        local caller = object(value.caller, spec.limits.request_bytes)
        local store <close> = make_store(config, NULL)
        store:caller(caller)
        local memory <close> = make_memory(config, store, make_model(config, NULL))
        return memory:expand(value.arguments[1], caller.memory_range)
    end

    function entry.pending(input, opaque)
        assert(input == "", "pending takes empty input")
        local store <close> = make_store(configuration(opaque), NULL)
        return encode_json(store:pending())
    end

    function entry.resume(input, opaque)
        local value = object(input, spec.limits.config_bytes)
        assert(math.type(value.run) == "integer" and value.run > 0, "resume requires run")
        for key in pairs(value) do
            assert(key == "run", "resume takes only run")
        end
        return encode_json(run(configuration(opaque), nil, nil, value.run))
    end

    function entry.abort(input, opaque)
        local value = object(input, spec.limits.config_bytes)
        assert(
            (math.type(value.run) == "integer" and value.run > 0) ~= (type(value.request) == "string")
                and type(value.reason) == "string"
                and #value.reason <= 2048,
            "abort requires run or request, and reason"
        )
        for key in pairs(value) do
            assert(key == "run" or key == "request" or key == "reason", "unknown abort field")
        end
        local store <close> = make_store(configuration(opaque), NULL)
        return encode_json(store:abort(value.run or value.request, value.reason))
    end

    function entry.events(input, opaque)
        local value = object(input, spec.limits.config_bytes)
        assert(
            math.type(value.run) == "integer"
                and value.run > 0
                and math.type(value.after or 0) == "integer"
                and (value.after or 0) >= 0,
            "invalid events coordinates"
        )
        for key in pairs(value) do
            assert(key == "run" or key == "after", "unknown events field")
        end
        local store <close> = make_store(configuration(opaque), NULL)
        return encode_json(store:events(value.run, value.after), NULL)
    end

    function entry.summarize(input, opaque)
        assert(input == "", "summarize takes empty input")
        local config = configuration(opaque)
        local store <close> = make_store(config, NULL)
        local model = make_model(config, NULL)
        local profile = model:select(config.chat, "chat")
        profile.output_tokens = profile.output_tokens or profile.context_tokens // 2
        local memory <close> = make_memory(config, store, model)
        return encode_json(memory:summarize(profile))
    end

    return setmetatable(entry, {
        __call = function(_, input, opaque)
            return encode_json(run(configuration(opaque), request(object(input, spec.limits.request_bytes))), NULL)
        end,
        __metatable = false,
    })
end
