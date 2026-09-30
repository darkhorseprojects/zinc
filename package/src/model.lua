local decode_json = require("lunajson.decoder")()
local encode_json = require("lunajson.encoder")()
local pa = require("pa")

local NULL = {}

local function decode(source)
    local value, offset = decode_json(source, 1, NULL)
    assert(source:sub(offset):match("^%s*$"), "JSON has trailing data")
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
    local size = #value
    for key in pairs(value) do
        assert(math.type(key) == "integer" and key >= 1 and key <= size, name .. " must be dense")
    end
    return value
end

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

return function(config)
    local chat, rerank = config.limits.chat, config.limits.rerank
    local api, catalogs = {}, {}

    function api:models(role, selected)
        assert(role == "chat" or role == "rerank", "unsupported model role")
        local output = { [0] = 0 }
        for name, provider in pairs(config.providers) do
            if (not selected or name == selected) and (role == "chat" or name == "llama") then
                if not catalogs[name] then
                    local status, body = pa.http(provider.url, "GET", "/v1/models", "", {
                        accept = "application/json",
                        authorization = provider.token and "Bearer " .. provider.token or nil,
                    }, chat.response_bytes)
                    assert(
                        status >= 200 and status < 300,
                        name .. " model catalog failed: HTTP " .. status .. "\n" .. body:sub(1, 2048)
                    )
                    local records = {}
                    for _, value in ipairs(dense(decode(body).data, "model catalog")) do
                        assert(type(value.id) == "string" and value.id ~= "", "invalid model ID")
                        local record = {
                            ref = name .. ":" .. value.id,
                            provider = name,
                            id = value.id,
                            name = value.name or value.id,
                        }
                        if name == "openrouter" then
                            record.input = value.architecture and value.architecture.input_modalities
                            record.context_tokens = value.context_length
                            record.output_tokens = value.top_provider and value.top_provider.max_completion_tokens
                            record.thinking, record.tools = false, false
                            for _, parameter in ipairs(value.supported_parameters or {}) do
                                record.thinking = record.thinking
                                    or parameter == "reasoning"
                                    or parameter == "reasoning_effort"
                                record.tools = record.tools or parameter == "tools"
                            end
                        elseif value.meta then
                            record.context_tokens = value.meta.n_ctx
                        end
                        records[#records + 1] = record
                    end
                    catalogs[name] = records
                end
                for _, record in ipairs(catalogs[name]) do
                    if role ~= "chat" or record.tools ~= false then
                        output[#output + 1] = record
                    end
                end
            end
        end
        table.sort(output, function(a, b)
            return a.ref < b.ref
        end)
        output[0] = #output
        return output
    end

    local function selection(reference, role)
        local provider, id = reference:match("^([%w_-]+):(.+)$")
        if provider then
            assert(config.providers[provider], "model provider is not configured: " .. provider)
            assert(role ~= "rerank" or provider == "llama", "rerank provider is unsupported")
        else
            id = reference
        end
        local selected
        for _, record in ipairs(api:models(role, provider)) do
            if record.id == id then
                assert(not selected, "ambiguous model ID; use a provider-qualified reference: " .. reference)
                selected = record
            end
        end
        assert(selected, "model is unavailable for " .. role .. ": " .. reference)
        return selected, config.providers[selected.provider]
    end

    local function request(provider, path, value, maximum)
        pa.log("model.http.begin")
        local status, body = pa.http(provider.url, "POST", path, encode_json(value, NULL), {
            ["content-type"] = "application/json",
            accept = "application/json",
            authorization = provider.token and "Bearer " .. provider.token or nil,
        }, maximum)
        pa.log("model.http.status." .. status)
        assert(status >= 200 and status < 300, "model endpoint failed: HTTP " .. status .. "\n" .. body:sub(1, 2048))
        local result = decode(body)
        assert(type(result) == "table" and type(result.error) ~= "table", "invalid model response")
        pa.log("model.http.end")
        return result
    end

    local function chat_body(messages, model)
        local body = {
            model = model.id,
            messages = messages,
            tools = { TOOL },
            parallel_tool_calls = true,
            max_tokens = math.min(chat.tokens, model.output_tokens or chat.tokens),
            stream = true,
            stream_options = { include_usage = true },
        }
        if model.provider == "llama" then
            body.chat_template_kwargs = { enable_thinking = config.thinking }
        elseif config.thinking then
            body.reasoning = { effort = "medium" }
        end
        return body
    end

    function api:chat(messages, branch)
        local model, provider = selection(config.model, "chat")
        assert(not config.thinking or model.thinking ~= false, "model does not support thinking: " .. model.ref)
        if model.input then
            for _, message in ipairs(messages) do
                if type(message.content) == "table" then
                    local images = false
                    for _, modality in ipairs(model.input) do
                        images = images or modality == "image"
                    end
                    assert(images, "model does not support images: " .. model.ref)
                end
            end
        end
        local fragments, data, error_body = {}, {}, {}
        local finished, done, usage, problem = nil, false, nil, nil
        local contents, thoughts, calls = {}, {}, {}
        local first_reasoning, first_content, first_tool = false, false, false
        local request_body = encode_json(chat_body(messages, model), NULL)
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
                            done = true
                        else
                            assert(not done, "unexpected chat stream data")
                            local value = decode(payload)
                            if value.usage ~= NULL and type(value.usage) == "table" then
                                assert(not usage, "duplicate chat usage")
                                local count = value.usage.total_tokens
                                assert(math.type(count) == "integer" and count >= 0, "invalid chat usage")
                                usage = count
                            end
                            if value.error ~= NULL and type(value.error) == "table" then
                                problem = model.ref .. ": " .. tostring(value.error.message or value.error.code)
                            elseif not problem then
                                local choices = dense(value.choices, "chat stream choices")
                                if #choices == 0 then
                                    assert(usage and finished, "unexpected empty chat choices")
                                else
                                    assert(#choices == 1, "chat stream has the wrong choice count")
                                    if finished then
                                        local accounting = choices[1]
                                        assert(
                                            usage
                                                and type(accounting) == "table"
                                                and type(accounting.delta) == "table"
                                                and next(accounting.delta) == nil
                                                and accounting.finish_reason == finished,
                                            "unexpected chat data after finish"
                                        )
                                    end
                                end
                                local choice = choices[1]
                                if choice then
                                    local delta = assert(
                                        type(choice) == "table" and type(choice.delta) == "table" and choice.delta,
                                        "invalid chat delta"
                                    )
                                    local reasoning_delta = delta.reasoning_content or delta.reasoning
                                    if type(reasoning_delta) == "string" and reasoning_delta ~= "" then
                                        if pa.profile and not first_reasoning then
                                            first_reasoning = true
                                            pa.log("model.chat.first_reasoning")
                                        end
                                        thoughts[#thoughts + 1] = reasoning_delta
                                        if config.thinking then
                                            pa.emit(encode_json({
                                                type = "delta",
                                                branch = branch,
                                                channel = "reasoning",
                                                text = reasoning_delta,
                                            }))
                                        end
                                    end
                                    if type(delta.content) == "string" and delta.content ~= "" then
                                        if pa.profile and not first_content then
                                            first_content = true
                                            pa.log("model.chat.first_content")
                                        end
                                        contents[#contents + 1] = delta.content
                                        pa.emit(encode_json({
                                            type = "delta",
                                            branch = branch,
                                            channel = "content",
                                            text = delta.content,
                                        }))
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
                                                id = "",
                                                type = "function",
                                                ["function"] = { name = "", arguments = "" },
                                            }
                                            calls[index + 1] = call
                                        end
                                        local fn = tool["function"]
                                        if type(tool.id) == "string" then
                                            call.id = call.id .. tool.id
                                        end
                                        if type(fn) == "table" then
                                            if type(fn.name) == "string" then
                                                call["function"].name = call["function"].name .. fn.name
                                            end
                                            if type(fn.arguments) == "string" then
                                                if pa.profile and not first_tool and fn.arguments ~= "" then
                                                    first_tool = true
                                                    pa.log("model.chat.first_tool_argument")
                                                end
                                                call["function"].arguments = call["function"].arguments .. fn.arguments
                                                assert(
                                                    #call["function"].arguments <= chat.argument_bytes,
                                                    "tool arguments are too large"
                                                )
                                            end
                                        end
                                    end
                                    if choice.finish_reason ~= nil and choice.finish_reason ~= NULL then
                                        finished = choice.finish_reason
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
            return { usage = usage, error = problem }
        end
        assert(
            done and finished and usage and #data == 0 and table.concat(fragments):match("^%s*$"),
            "chat stream ended early or omitted usage"
        )
        pa.log("model.http.end")
        if finished == "length" then
            pa.log("model.chat.length")
            return { usage = usage, truncated = true }
        end
        local parsed = table.pack(pcall(function()
            local reasoning = #thoughts > 0 and table.concat(thoughts) or nil
            local content = #contents > 0 and table.concat(contents) or nil
            assert(not reasoning or utf8.len(reasoning), "invalid reasoning")
            assert(not content or utf8.len(content), "invalid response")

            local entries = dense(calls, "chat tool calls")
            local decoded_calls, tool_calls, ids = {}, {}, {}
            for index, entry in ipairs(entries) do
                local fn = type(entry) == "table" and entry["function"]
                local id = type(entry) == "table" and entry.id
                local name = type(fn) == "table" and fn.name
                local arguments = type(fn) == "table" and fn.arguments
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
                tool_calls[index] =
                    { id = id, type = "function", ["function"] = { name = name, arguments = arguments } }
            end

            assert(finished == "stop" or finished == "tool_calls", "invalid tool completion")
            pa.log("model.chat.finish." .. finished)
            if #decoded_calls == 0 then
                assert(finished == "stop" and (content or reasoning), "chat completion has no response")
            end
            pa.log("model.chat.decoded")
            return {
                reasoning = reasoning,
                content = content,
                calls = decoded_calls,
                tool_calls = tool_calls,
                usage = usage,
            }
        end))
        if not parsed[1] then
            return { usage = usage, error = tostring(parsed[2]) }
        end
        return parsed[2]
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
        local model, provider = selection(config.rerank, "rerank")
        local response = request(provider, "/v1/rerank", {
            model = model.id,
            documents = selected,
            query = query,
            top_n = #selected,
        }, chat.response_bytes)
        pa.log("model.rerank.end")
        local usage = response.usage and response.usage.total_tokens
        assert(math.type(usage) == "integer" and usage >= 0, "invalid reranker usage")
        local parsed = table.pack(pcall(function()
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
        end))
        if not parsed[1] then
            return {}, usage, tostring(parsed[2])
        end
        return parsed[2], usage
    end

    return api
end
