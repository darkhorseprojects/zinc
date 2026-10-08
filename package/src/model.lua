local decode_json = require("lunajson.decoder")()
local encode_json = require("lunajson.encoder")()
local pa = require("pa")

local TOOL = {
    type = "function",
    ["function"] = {
        name = "run_lua",
        description = "Evaluate Lua source.",
        parameters = {
            type = "object",
            additionalProperties = false,
            required = { "code" },
            properties = { code = { type = "string", description = "Source." } },
        },
    },
}

local function dense(value, name)
    assert(type(value) == "table", name .. " must be an array")
    local size, count = #value, 0
    for key in pairs(value) do
        assert(math.type(key) == "integer" and key >= 1 and key <= size, name .. " must be dense")
        count = count + 1
    end
    assert(count == size, name .. " must be dense")
    return value
end

return function(config, null)
    local api, catalogs, profiles = {}, {}, {}

    local function decode(source)
        local value, offset = decode_json(source, 1, null)
        assert(source:sub(offset):match("^[ \t\r\n]*$"), "JSON has trailing data")
        return value
    end

    local function request(provider, method, path, value)
        local status, body = pa.http(provider.url, method, path, value and encode_json(value, null) or "", {
            ["content-type"] = value and "application/json" or nil,
            accept = "application/json",
            authorization = provider.token and "Bearer " .. provider.token or nil,
        }, 8388608)
        assert(status >= 200 and status < 300, "model endpoint failed: HTTP " .. status)
        local result = decode(body)
        assert(type(result) == "table" and (result.error == nil or result.error == null), "invalid model response")
        return result
    end

    local function catalog(name, role)
        local key = name .. ":" .. role
        if not catalogs[key] then
            local path = "/v1/models"
            if name == "openrouter" then
                path = path .. "?output_modalities=" .. (role == "chat" and "text" or "rerank")
            end
            local records = dense(request(config.providers[name], "GET", path).data, "model catalog")
            local by_id = {}
            for _, record in ipairs(records) do
                assert(type(record.id) == "string" and record.id ~= "" and not by_id[record.id], "invalid model ID")
                by_id[record.id] = record
            end
            catalogs[key] = { records = records, by_id = by_id }
        end
        return catalogs[key]
    end

    function api:models(role)
        assert(role == "chat" or role == "rerank", "unsupported model role")
        local output = { [0] = 0 }
        for name in pairs(config.providers) do
            for _, record in ipairs(catalog(name, role).records) do
                output[#output + 1] = { ref = name .. ":" .. record.id, name = record.name or record.id }
            end
        end
        table.sort(output, function(a, b)
            return a.ref < b.ref
        end)
        output[0] = #output
        return output
    end

    function api:select(reference, role)
        assert(role == "chat" or role == "rerank", "unsupported model role")
        local key = reference .. ":" .. role
        if profiles[key] then
            return profiles[key], config.providers[profiles[key].provider]
        end
        local name, id = reference:match("^([%w_-]+):(.+)$")
        assert(name, "model reference must be provider-qualified: " .. reference)
        local provider = assert(config.providers[name], "model provider is not configured: " .. name)
        local model = { ref = reference, provider = name, id = id }
        if name == "llama" then
            local query = id:gsub("[^%w_.~-]", function(byte)
                return string.format("%%%02X", byte:byte())
            end)
            local props = request(provider, "GET", "/props?model=" .. query)
            model.context_tokens = props.default_generation_settings.n_ctx
            if role == "chat" then
                local caps = assert(props.chat_template_caps, "missing template capabilities")
                model.images = props.modalities.vision == true
                model.tools = caps.supports_tools == true and caps.supports_tool_calls == true
                model.parallel = caps.supports_parallel_tool_calls == true
                model.reasoning = caps.supports_reasoning_effort and "reasoning_effort" or nil
            end
        else
            local record = assert(catalog(name, role).by_id[id], "model is not available: " .. reference)
            model.context_tokens = record.context_length
            if role == "chat" then
                local top = assert(record.top_provider, "missing model capacity")
                assert(
                    math.type(record.context_length) == "integer"
                        and record.context_length > 1
                        and math.type(top.context_length) == "integer"
                        and top.context_length > 1,
                    "invalid provider context"
                )
                assert(
                    top.max_completion_tokens == null
                        or math.type(top.max_completion_tokens) == "integer" and top.max_completion_tokens > 0,
                    "invalid model output ceiling"
                )
                model.context_tokens = math.min(record.context_length, top.context_length)
                model.output_tokens = top.max_completion_tokens ~= null and top.max_completion_tokens or nil
                local parameters = {}
                for _, parameter in ipairs(dense(record.supported_parameters, "model parameters")) do
                    parameters[parameter] = true
                end
                model.tools = parameters.tools == true
                model.parallel = parameters.parallel_tool_calls == true
                model.reasoning = parameters.reasoning and "reasoning"
                    or parameters.reasoning_effort and "reasoning_effort"
                    or nil
                for _, modality in ipairs(dense(record.architecture.input_modalities, "input modalities")) do
                    model.images = model.images or modality == "image"
                end
                local reasoning = record.reasoning ~= null and record.reasoning or nil
                if config.thinking == "none" then
                    assert(not (reasoning and reasoning.mandatory), reference .. " requires reasoning")
                else
                    local efforts = reasoning and reasoning.supported_efforts
                    local allowed = efforts == null
                        or reasoning and reasoning.supports_max_tokens == true and efforts == nil
                    for _, effort in ipairs(efforts ~= null and efforts or {}) do
                        allowed = allowed or effort == config.thinking
                    end
                    assert(allowed, reference .. " does not support thinking=" .. config.thinking)
                end
            end
        end
        assert(math.type(model.context_tokens) == "integer" and model.context_tokens > 1, "invalid model context")
        assert(
            role ~= "chat" or config.thinking == "none" or model.reasoning,
            reference .. " has no reasoning control; use thinking=none"
        )
        profiles[key] = model
        return model, provider
    end

    function api:chat(messages, branch, model, output_tokens)
        local provider = config.providers[model.provider]
        local body = {
            model = model.id,
            messages = messages,
            max_tokens = math.min(model.output_tokens or model.context_tokens, output_tokens),
            stream = true,
            stream_options = { include_usage = true },
        }
        if branch and model.tools then
            body.tools = { TOOL }
            body.parallel_tool_calls = model.parallel and true or nil
        end
        if model.reasoning == "reasoning" then
            body.reasoning = config.thinking == "none" and { enabled = false } or { effort = config.thinking }
        elseif model.reasoning == "reasoning_effort" then
            body.reasoning_effort = config.thinking
        end
        if model.provider == "openrouter" then
            body.provider = { require_parameters = true, allow_fallbacks = false }
            body.session_id = config.actor
        end
        local fragments, data = {}, {}
        local finished, done, usage, first_tool = nil, false, nil, false
        local contents, thoughts, calls, details = {}, {}, {}, {}
        local channels = {
            { name = "reasoning", field = "reasoning_content", parts = thoughts, emit = config.thinking ~= "none" },
            { name = "content", field = "content", parts = contents, emit = true },
        }
        local status = pa.http(
            provider.url,
            "POST",
            "/v1/chat/completions",
            encode_json(body, null),
            {
                ["content-type"] = "application/json",
                accept = "text/event-stream",
                authorization = provider.token and "Bearer " .. provider.token or nil,
            },
            8388608,
            function(code, chunk)
                if code < 200 or code >= 300 then
                    return
                end
                local start = 1
                while true do
                    local boundary = chunk:find("\n", start, true)
                    if not boundary then
                        fragments[#fragments + 1] = chunk:sub(start)
                        break
                    end
                    fragments[#fragments + 1] = chunk:sub(start, boundary - 1)
                    local line = table.concat(fragments):gsub("\r$", "")
                    fragments, start = {}, boundary + 1
                    if line:sub(1, 5) == "data:" then
                        data[#data + 1] = line:sub(6):gsub("^ ", "")
                    elseif line == "" and #data > 0 then
                        local payload = table.concat(data, "\n")
                        data = {}
                        assert(not done, "unexpected data after chat completion")
                        if payload == "[DONE]" then
                            done = true
                        else
                            local value = decode(payload)
                            assert(
                                value.error == nil or value.error == null,
                                model.ref .. ": provider reported a stream error"
                            )
                            if type(value.usage) == "table" and value.usage ~= null then
                                usage = value.usage
                            end
                            local choices = dense(value.choices, "chat choices")
                            assert(#choices <= 1, "wrong chat choice count")
                            local choice = choices[1]
                            if not choice then
                                assert(
                                    finished and value.usage ~= nil and value.usage ~= null,
                                    "unexpected empty choices"
                                )
                            else
                                local delta, reason = choice.delta, choice.finish_reason
                                if delta == nil or delta == null then
                                    assert(finished, "missing chat delta")
                                    delta = {}
                                end
                                assert(type(delta) == "table", "invalid chat delta")
                                assert(
                                    delta.role == nil or delta.role == null or delta.role == "assistant",
                                    "invalid assistant role"
                                )
                                if finished then
                                    assert(
                                        reason == nil or reason == null or reason == finished,
                                        "chat finish reason changed"
                                    )
                                    for key, item in pairs(delta) do
                                        assert(
                                            key == "content" and (item == "" or item == null)
                                                or key == "role" and item == "assistant",
                                            "chat data after finish"
                                        )
                                    end
                                end
                                for _, detail in ipairs(dense(delta.reasoning_details or {}, "reasoning details")) do
                                    details[#details + 1] = detail
                                end
                                for _, channel in ipairs(channels) do
                                    local text = delta[channel.field]
                                        or (channel.name == "reasoning" and delta.reasoning)
                                    if type(text) == "string" and text ~= "" then
                                        if #channel.parts == 0 then
                                            pa.log("model.chat.first_" .. channel.name)
                                        end
                                        channel.parts[#channel.parts + 1] = text
                                        if branch and channel.emit then
                                            pa.emit(encode_json({
                                                type = "delta",
                                                branch = branch,
                                                channel = channel.name,
                                                text = text,
                                            }))
                                        end
                                    end
                                end
                                for _, tool in ipairs(dense(delta.tool_calls or {}, "tool deltas")) do
                                    local index = tool.index
                                    assert(
                                        math.type(index) == "integer" and index >= 0 and index < 16,
                                        "invalid tool index"
                                    )
                                    assert(
                                        tool.type == nil or tool.type == null or tool.type == "function",
                                        "invalid tool type"
                                    )
                                    assert(
                                        tool.id == nil or tool.id == null or type(tool.id) == "string",
                                        "invalid tool ID"
                                    )
                                    local call = calls[index + 1]
                                    if not call then
                                        call = { ids = {}, names = {}, arguments = {} }
                                        calls[index + 1] = call
                                    end
                                    if type(tool.id) == "string" then
                                        call.ids[#call.ids + 1] = tool.id
                                    end
                                    local fn = tool["function"]
                                    assert(fn == nil or type(fn) == "table", "invalid tool function")
                                    if type(fn) == "table" then
                                        assert(
                                            fn.name == nil or fn.name == null or type(fn.name) == "string",
                                            "invalid tool name"
                                        )
                                        assert(
                                            fn.arguments == nil
                                                or fn.arguments == null
                                                or type(fn.arguments) == "string",
                                            "invalid tool arguments"
                                        )
                                        if type(fn.name) == "string" then
                                            call.names[#call.names + 1] = fn.name
                                        end
                                        if type(fn.arguments) == "string" then
                                            if not first_tool and fn.arguments ~= "" then
                                                first_tool = true
                                                pa.log("model.chat.first_tool_argument")
                                            end
                                            call.arguments[#call.arguments + 1] = fn.arguments
                                        end
                                    end
                                end
                                if reason ~= nil and reason ~= null then
                                    finished = reason
                                end
                            end
                        end
                    end
                end
            end
        )
        assert(status >= 200 and status < 300, model.ref .. " failed: HTTP " .. status)
        assert(done and finished and #data == 0 and table.concat(fragments):match("^%s*$"), "chat stream ended early")
        assert(finished == "stop" or finished == "tool_calls", "incomplete chat: finish_reason=" .. tostring(finished))
        if usage then
            for _, field in ipairs({ "prompt_tokens", "completion_tokens", "total_tokens" }) do
                if math.type(usage[field]) == "integer" and usage[field] >= 0 then
                    pa.log("model.usage." .. field .. "." .. usage[field])
                end
            end
            if type(usage.prompt_tokens_details) == "table" then
                for field, count in pairs(usage.prompt_tokens_details) do
                    if
                        (field == "cached_tokens" or field == "cache_write_tokens")
                        and math.type(count) == "integer"
                    then
                        pa.log("model.cache." .. field .. "." .. count)
                    end
                end
            end
        end
        local content, reasoning = table.concat(contents), #thoughts > 0 and table.concat(thoughts) or nil
        assert(utf8.len(content) and (not reasoning or utf8.len(reasoning)), "invalid assistant UTF-8")
        local entries, tools, seen = {}, {}, {}
        for index, call in ipairs(dense(calls, "tool calls")) do
            local id, name, arguments = table.concat(call.ids), table.concat(call.names), table.concat(call.arguments)
            assert(id ~= "" and utf8.len(id) and not seen[id] and name == "run_lua", "invalid tool call")
            local value = decode(arguments)
            assert(
                type(value) == "table" and type(value.code) == "string" and value.code ~= "" and utf8.len(value.code),
                "invalid tool source"
            )
            for key in pairs(value) do
                assert(key == "code", "unknown tool argument")
            end
            entries[index] = { id = id, type = "function", ["function"] = { name = name, arguments = arguments } }
            tools[index], seen[id] = { id = id, code = value.code, arguments = arguments }, true
        end
        assert(branch and model.tools or #tools == 0, "unsupported tool calls")
        assert(#tools > 0 or finished == "stop" and content ~= "", "chat completion has no response")
        return {
            role = "assistant",
            content = content,
            tool_calls = #entries > 0 and entries or nil,
            reasoning_content = model.provider == "llama" and reasoning or nil,
            reasoning = model.provider == "openrouter" and #details == 0 and reasoning or nil,
            reasoning_details = model.provider == "openrouter" and #details > 0 and details or nil,
        },
            tools,
            reasoning
    end

    function api:rerank(query, passages)
        if #passages == 0 then
            return {}
        end
        local model, provider = self:select(config.rerank, "rerank")
        if #query > model.context_tokens then
            query = query:sub(1, utf8.offset(query, 0, model.context_tokens + 1) - 1)
            pa.log("memory.rerank.query_truncated")
        end
        local selected = {}
        local maximum = model.context_tokens * 4 - #query - 128
        assert(maximum > 0, "reranker context leaves no passage capacity")
        for index, passage in ipairs(passages) do
            selected[index] = #passage <= maximum and passage
                or passage:sub(1, utf8.offset(passage, 0, maximum + 1) - 1)
        end
        pa.log("model.rerank.begin")
        local response = request(provider, "POST", "/v1/rerank", {
            model = model.id,
            documents = selected,
            query = query,
            top_n = #selected,
        })
        pa.log("model.rerank.end")
        local ranked = dense(response.results, "reranker results")
        assert(#ranked == #selected, "wrong reranker result count")
        local output, seen = {}, {}
        for _, entry in ipairs(ranked) do
            local index = type(entry.index) == "number" and math.tointeger(entry.index)
            local score = entry.relevance_score
            assert(index and index >= 0 and index < #selected and not seen[index], "invalid reranker index")
            assert(type(score) == "number" and score == score and math.abs(score) < math.huge, "invalid reranker score")
            output[#output + 1], seen[index] = { index = index + 1, score = score }, true
        end
        table.sort(output, function(a, b)
            return a.score > b.score or a.score == b.score and a.index < b.index
        end)
        return output
    end

    return api
end
