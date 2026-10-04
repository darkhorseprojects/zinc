local decode_json = require("lunajson.decoder")()
local encode_json = require("lunajson.encoder")()
local pa = require("pa")

local NULL = {}

local function decode(source)
    local value, offset = decode_json(source, 1, NULL)
    assert(source:sub(offset):match("^[ \t\r\n]*$"), "JSON has trailing data")
    return value
end

local TOOL = {
    type = "function",
    ["function"] = {
        name = "run_lua",
        description = "Evaluate Lua source.",
        parameters = {
            type = "object",
            additionalProperties = false,
            required = { "code" },
            properties = {
                code = { type = "string", description = "Source." },
            },
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

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

return function(config)
    local chat, rerank = config.limits.chat, config.limits.rerank
    local api, catalogs = {}, {}

    local function request(provider, method, path, value)
        pa.log("model.http.begin")
        local status, body = pa.http(provider.url, method, path, value and encode_json(value, NULL) or "", {
            ["content-type"] = value and "application/json" or nil,
            accept = "application/json",
            authorization = provider.token and "Bearer " .. provider.token or nil,
        }, chat.response_bytes)
        pa.log("model.http.status." .. status)
        assert(status >= 200 and status < 300, "model endpoint failed: HTTP " .. status .. "\n" .. body:sub(1, 2048))
        local result = decode(body)
        assert(type(result) == "table" and (result.error == nil or result.error == NULL), "invalid model response")
        pa.log("model.http.end")
        return result
    end

    local function catalog(name, role)
        local key = name .. ":" .. role
        if not catalogs[key] then
            local path = "/v1/models"
            if name == "openrouter" then
                path = path .. "?output_modalities=" .. (role == "chat" and "text" or "rerank")
            end
            catalogs[key] = dense(request(config.providers[name], "GET", path).data, "model catalog")
        end
        return catalogs[key]
    end

    function api:models(role)
        assert(role == "chat" or role == "rerank", "unsupported model role")
        local output = { [0] = 0 }
        for name in pairs(config.providers) do
            for _, value in ipairs(catalog(name, role)) do
                assert(type(value.id) == "string" and value.id ~= "", "invalid model ID")
                output[#output + 1] = { ref = name .. ":" .. value.id, name = value.name or value.id }
            end
        end
        table.sort(output, function(a, b)
            return a.ref < b.ref
        end)
        output[0] = #output
        return output
    end

    function api:select(reference, role)
        local name, id = reference:match("^([%w_-]+):(.+)$")
        assert(name, "model reference must be provider-qualified: " .. reference)
        local provider = assert(config.providers[name], "model provider is not configured: " .. name)
        local model = { ref = reference, provider = name, id = id }
        if role == "rerank" then
            return model, provider
        end
        assert(role == "chat", "unsupported model role")
        if name == "llama" then
            local query = id:gsub("[^%w_.~-]", function(byte)
                return string.format("%%%02X", byte:byte())
            end)
            local props = request(provider, "GET", "/props?model=" .. query)
            local caps = assert(props.chat_template_caps, "missing template capabilities")
            model.context_tokens = props.default_generation_settings.n_ctx
            model.images = props.modalities.vision == true
            model.tools = caps.supports_tools == true and caps.supports_tool_calls == true
            model.parallel = caps.supports_parallel_tool_calls == true
            model.reasoning = caps.supports_reasoning_effort and "reasoning_effort" or nil
        else
            local record
            for _, value in ipairs(catalog(name, "chat")) do
                if value.id == id then
                    record = value
                    break
                end
            end
            assert(record, "chat model is not available: " .. reference)
            local top = assert(record.top_provider, "missing model capacity")
            assert(
                math.type(record.context_length) == "integer"
                    and record.context_length > 1
                    and math.type(top.context_length) == "integer"
                    and top.context_length > 1,
                "invalid model context"
            )
            assert(
                top.max_completion_tokens == NULL
                    or math.type(top.max_completion_tokens) == "integer" and top.max_completion_tokens > 0,
                "invalid model output ceiling"
            )
            model.context_tokens = math.min(record.context_length, top.context_length)
            model.output_tokens = top.max_completion_tokens ~= NULL and top.max_completion_tokens or nil
            local parameters = {}
            for _, parameter in ipairs(dense(record.supported_parameters, "model parameters")) do
                parameters[parameter] = true
            end
            model.tools = parameters.tools == true
            model.parallel = parameters.parallel_tool_calls == true
            model.reasoning = parameters.reasoning and "reasoning"
                or parameters.reasoning_effort and "reasoning_effort"
                or nil
            model.images = false
            for _, modality in ipairs(dense(record.architecture.input_modalities, "input modalities")) do
                model.images = model.images or modality == "image"
            end
            local reasoning = record.reasoning ~= NULL and record.reasoning or nil
            if config.thinking == "none" then
                assert(not (reasoning and reasoning.mandatory), reference .. " requires reasoning")
            else
                local efforts = reasoning and reasoning.supported_efforts
                local allowed = efforts == NULL
                    or reasoning and reasoning.supports_max_tokens == true and efforts == nil
                for _, effort in ipairs(efforts ~= NULL and efforts or {}) do
                    allowed = allowed or effort == config.thinking
                end
                assert(allowed, reference .. " does not support thinking=" .. config.thinking)
            end
        end
        assert(math.type(model.context_tokens) == "integer" and model.context_tokens > 1, "invalid model context")
        assert(
            config.thinking == "none" or model.reasoning,
            reference .. " has no reasoning control; use thinking=none"
        )
        return model, provider
    end

    function api:chat(messages, branch, model, remaining)
        local provider = config.providers[model.provider]
        local body = {
            model = model.id,
            messages = messages,
            max_tokens = math.min(model.output_tokens, remaining),
            stream = true,
            stream_options = { include_usage = true },
        }
        if model.tools then
            body.tools = { TOOL }
            if model.parallel then
                body.parallel_tool_calls = true
            end
        end
        if model.reasoning == "reasoning" then
            body.reasoning = config.thinking == "none" and { enabled = false } or { effort = config.thinking }
        elseif model.reasoning == "reasoning_effort" then
            body.reasoning_effort = config.thinking
        end
        if model.provider == "openrouter" then
            body.provider = { require_parameters = true, allow_fallbacks = false }
        else
            request(provider, "POST", "/apply-template", body)
        end
        local fragments, data, error_body = {}, {}, {}
        local finished, done, usage, problem = nil, false, nil, nil
        local contents, thoughts, calls, details = {}, {}, {}, {}
        local channels = {
            { name = "reasoning", field = "reasoning_content", parts = thoughts, emit = config.thinking ~= "none" },
            { name = "content", field = "content", parts = contents, emit = true },
        }
        local first_tool = false
        local request_body = encode_json(body, NULL)
        pa.log("model.http.begin")
        local status = pa.http(
            provider.url,
            "POST",
            "/v1/chat/completions",
            request_body,
            {
                ["content-type"] = "application/json",
                accept = "text/event-stream",
                authorization = provider.token and "Bearer " .. provider.token or nil,
            },
            chat.response_bytes,
            function(code, chunk)
                if code < 200 or code >= 300 then
                    local size = 0
                    for _, part in ipairs(error_body) do
                        size = size + #part
                    end
                    if size < 4096 then
                        error_body[#error_body + 1] = chunk:sub(1, 4096 - size)
                    end
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
                    local line = table.concat(fragments)
                    fragments = {}
                    start = boundary + 1
                    if line:sub(-1) == "\r" then
                        line = line:sub(1, -2)
                    end
                    if line:sub(1, 5) == "data:" then
                        data[#data + 1] = line:sub(6):gsub("^ ", "")
                    elseif line == "" and #data > 0 then
                        local payload = table.concat(data, "\n")
                        data = {}
                        if payload == "[DONE]" then
                            assert(not done, "duplicate chat completion marker")
                            done = true
                        else
                            assert(not done, "unexpected chat stream data")
                            local value = decode(payload)
                            if value.usage ~= NULL and type(value.usage) == "table" then
                                assert(not usage, "duplicate chat usage")
                                local count = value.usage.total_tokens
                                assert(math.type(count) == "integer" and count >= 0, "invalid chat usage")
                                usage = value.usage
                            end
                            if value.error ~= NULL and type(value.error) == "table" then
                                problem = model.ref .. ": " .. tostring(value.error.message or value.error.code)
                            elseif not problem then
                                local choices = dense(value.choices, "chat stream choices")
                                assert(#choices <= 1, "chat stream has the wrong choice count")
                                local choice = choices[1]
                                if #choices == 0 then
                                    assert(
                                        finished and type(value.usage) == "table" and value.usage ~= NULL,
                                        "unexpected empty chat choices"
                                    )
                                else
                                    assert(type(choice) == "table" and choice ~= NULL, "invalid chat choice")
                                    local delta, reason = choice.delta, choice.finish_reason
                                    if finished and (delta == nil or delta == NULL) then
                                        delta = {}
                                    end
                                    assert(type(delta) == "table" and delta ~= NULL, "invalid chat delta")
                                    if finished then
                                        assert(
                                            reason == nil or reason == NULL or reason == finished,
                                            "chat finish reason changed"
                                        )
                                        for key, item in pairs(delta) do
                                            assert(
                                                key == "content" and (item == "" or item == NULL)
                                                    or key == "role" and item == "assistant",
                                                "unexpected chat delta after finish: " .. tostring(key)
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
                                            if pa.profile and not channel.first then
                                                channel.first = true
                                                pa.log("model.chat.first_" .. channel.name)
                                            end
                                            channel.parts[#channel.parts + 1] = text
                                            if channel.emit then
                                                pa.emit(encode_json({
                                                    type = "delta",
                                                    branch = branch,
                                                    channel = channel.name,
                                                    text = text,
                                                }))
                                            end
                                        end
                                    end
                                    for _, tool in ipairs(dense(delta.tool_calls or {}, "chat stream tool calls")) do
                                        local index = type(tool) == "table" and tool.index
                                        assert(
                                            math.type(index) == "integer" and index >= 0 and index < chat.calls,
                                            "invalid tool call index"
                                        )
                                        local call = calls[index + 1]
                                        if not call then
                                            call = {
                                                ids = {},
                                                names = {},
                                                arguments = {},
                                                bytes = 0,
                                            }
                                            calls[index + 1] = call
                                        end
                                        local fn = tool["function"]
                                        if type(tool.id) == "string" then
                                            call.ids[#call.ids + 1] = tool.id
                                        end
                                        if type(fn) == "table" then
                                            if type(fn.name) == "string" then
                                                call.names[#call.names + 1] = fn.name
                                            end
                                            if type(fn.arguments) == "string" then
                                                if pa.profile and not first_tool and fn.arguments ~= "" then
                                                    first_tool = true
                                                    pa.log("model.chat.first_tool_argument")
                                                end
                                                call.bytes = call.bytes + #fn.arguments
                                                assert(
                                                    call.bytes <= chat.argument_bytes,
                                                    "tool arguments are too large"
                                                )
                                                call.arguments[#call.arguments + 1] = fn.arguments
                                            end
                                        end
                                    end
                                    if not finished and reason ~= nil and reason ~= NULL then
                                        finished = reason
                                        local timings = value.timings
                                        if type(timings) == "table" then
                                            if math.type(timings.prompt_n) == "integer" then
                                                pa.log("model.chat.prompt." .. timings.prompt_n)
                                            end
                                            if math.type(timings.predicted_n) == "integer" then
                                                pa.log("model.chat.completion." .. timings.predicted_n)
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        )
        pa.log("model.http.status." .. status)
        if status < 200 or status >= 300 then
            return { error = model.ref .. " failed: HTTP " .. status .. "\n" .. table.concat(error_body) }
        end
        if problem then
            return { usage = usage and usage.total_tokens, error = problem }
        end
        assert(
            done and finished and usage and #data == 0 and table.concat(fragments):match("^%s*$"),
            "chat stream ended early or omitted usage"
        )
        pa.log("model.http.end")
        if finished == "length" then
            pa.log("model.chat.length")
            return { usage = usage.total_tokens, truncated = true, limit = body.max_tokens, accounting = usage }
        end
        local decoded, result = pcall(function()
            local reasoning = #thoughts > 0 and table.concat(thoughts) or nil
            local content = #contents > 0 and table.concat(contents) or nil
            assert(not reasoning or utf8.len(reasoning), "invalid reasoning")
            assert(not content or utf8.len(content), "invalid response")

            local entries, decoded_calls, ids = {}, {}, {}
            for index, call in ipairs(dense(calls, "chat tool calls")) do
                local id = table.concat(call.ids)
                local name = table.concat(call.names)
                local arguments = table.concat(call.arguments)
                entries[index] = {
                    id = id,
                    type = "function",
                    ["function"] = { name = name, arguments = arguments },
                }
                assert(type(id) == "string" and id ~= "" and utf8.len(id) and not ids[id], "invalid tool call")
                assert(name == "run_lua" and type(arguments) == "string", "invalid tool call")
                assert(#arguments <= chat.argument_bytes, "tool arguments are too large")
                local decoded = decode(arguments)
                assert(type(decoded) == "table", "invalid tool arguments")
                for key in pairs(decoded) do
                    assert(key == "code", "unknown tool argument")
                end
                assert(
                    type(decoded.code) == "string"
                        and decoded.code ~= ""
                        and utf8.len(decoded.code)
                        and #decoded.code <= chat.source_bytes,
                    "invalid tool source"
                )
                ids[id] = true
                decoded_calls[index] = { id = id, code = decoded.code }
            end

            assert(finished == "stop" or finished == "tool_calls", "invalid tool completion")
            assert(model.tools or #decoded_calls == 0, "model returned unsupported tool calls")
            pa.log("model.chat.finish." .. finished)
            if #decoded_calls == 0 then
                assert(finished == "stop" and content, "chat completion has no response")
            end
            pa.log("model.chat.decoded")
            return {
                reasoning = reasoning,
                reasoning_details = #details > 0 and details or nil,
                content = content,
                calls = decoded_calls,
                tool_calls = entries,
                usage = usage.total_tokens,
            }
        end)
        if not decoded then
            return { usage = usage.total_tokens, error = tostring(result) }
        end
        return result
    end

    function api:rerank(query, passages)
        if #query > rerank.query_bytes then
            return {}, 0
        end
        local selected, source = {}, {}
        for index, passage in ipairs(passages) do
            if #query + 1 + #passage <= rerank.pair_bytes then
                selected[#selected + 1], source[#source + 1] = passage, index
            end
        end
        if #selected == 0 then
            return {}, 0
        end
        pa.log("model.rerank.begin")
        local model, provider = self:select(config.rerank, "rerank")
        local response = request(provider, "POST", "/v1/rerank", {
            model = model.id,
            documents = selected,
            query = query,
            top_n = #selected,
        })
        pa.log("model.rerank.end")
        local usage = response.usage and response.usage.total_tokens
        assert(math.type(usage) == "integer" and usage >= 0, "invalid reranker usage")
        local decoded, result = pcall(function()
            local ranked = dense(response.results, "reranker results")
            assert(#ranked == #selected, "reranker response has the wrong count")
            local output, seen = {}, {}
            for _, entry in ipairs(ranked) do
                local index = type(entry) == "table" and math.tointeger(entry.index)
                assert(index and index >= 0 and index < #selected and not seen[index], "reranker index is invalid")
                assert(finite(entry.relevance_score), "reranker score is invalid")
                seen[index], output[#output + 1] = true, { index = source[index + 1], score = entry.relevance_score }
            end
            return output
        end)
        if not decoded then
            return {}, usage, tostring(result)
        end
        return result, usage
    end

    return api
end
