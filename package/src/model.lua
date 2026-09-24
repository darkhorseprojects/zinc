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

return function(endpoints, config)
    local chat, rerank = config.chat, config.rerank

    local function request(path, value, maximum)
        pa.log("model.http.begin")
        local status, body = pa.http(endpoints.origin, "POST", path, encode_json(value, NULL), {
            ["content-type"] = "application/json",
            accept = "application/json",
        }, maximum)
        pa.log("model.http.status." .. status)
        assert(status >= 200 and status < 300, "model endpoint failed: HTTP " .. status)
        local result = decode(body)
        assert(type(result) == "table" and type(result.error) ~= "table", "invalid model response")
        pa.log("model.http.end")
        return result
    end

    local function post(model, path, value, maximum)
        value.model = model.name
        return request(path, value, maximum or chat.maximum_response_bytes)
    end

    local function tokens(model, path, content, special)
        pa.log("model.tokenize.begin")
        local result = post(model, path, {
            content = content,
            add_special = false,
            parse_special = special or false,
        }, chat.maximum_response_bytes)
        pa.log("model.tokenize.end")
        return #dense(result.tokens, "tokenizer tokens")
    end

    local api = {}

    function api:tokens(content)
        return tokens(chat, endpoints.chat.tokenize, content)
    end

    function api:context()
        local path = endpoints.chat.props
            .. "?model="
            .. chat.name:gsub("([^%w%-._~])", function(byte)
                return string.format("%%%02X", byte:byte())
            end)
        local status, body = pa.http(endpoints.origin, "GET", path, nil, nil, 65536)
        assert(status >= 200 and status < 300, "model properties failed: HTTP " .. status)
        local value = decode(body)
        local settings = type(value) == "table" and value.default_generation_settings
        local context = type(settings) == "table" and settings.n_ctx
        assert(math.type(context) == "integer" and context > 0, "invalid context")
        return context
    end

    local function chat_body(messages)
        return {
            model = chat.name,
            messages = messages,
            tools = { TOOL },
            parallel_tool_calls = true,
            max_tokens = chat.maximum_output_tokens,
            chat_template_kwargs = { enable_thinking = chat.thinking },
            stream = true,
        }
    end

    function api:prompt_tokens(messages)
        if pa.profile then
            pa.log("model.template.begin")
        end
        local result = request(endpoints.chat.template, chat_body(messages), chat.maximum_response_bytes)
        if pa.profile then
            pa.log("model.template.end")
        end
        assert(type(result.prompt) == "string", "invalid chat template")
        return tokens(chat, endpoints.chat.tokenize, result.prompt, true)
    end

    function api:chat(messages)
        local fragments = {}
        local finished, done = nil, false
        local contents, thoughts, calls = {}, {}, {}
        local streamed_kind
        local quote_start = false
        local first_reasoning, first_content, first_tool = false, false, false
        local request_body = encode_json(chat_body(messages), NULL)
        pa.log("model.http.begin")
        local status = pa.http(
            endpoints.origin,
            "POST",
            endpoints.chat.endpoint,
            request_body,
            {
                ["content-type"] = "application/json",
                accept = "text/event-stream",
            },
            chat.maximum_response_bytes,
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
                    local line = table.concat(fragments)
                    fragments = {}
                    start = boundary + 1
                    if line:sub(-1) == "\r" then
                        line = line:sub(1, -2)
                    end
                    if line:sub(1, 6) == "data: " then
                        local payload = line:sub(7)
                        if payload == "[DONE]" then
                            done = true
                        else
                            assert(not done and not finished, "unexpected chat stream data")
                            local value = decode(payload)
                            local choices = dense(value.choices, "chat stream choices")
                            assert(#choices == 1, "chat stream has the wrong choice count")
                            local choice = choices[1]
                            local delta = assert(
                                type(choice) == "table" and type(choice.delta) == "table" and choice.delta,
                                "invalid chat delta"
                            )
                            if type(delta.reasoning_content) == "string" and delta.reasoning_content ~= "" then
                                if pa.profile and not first_reasoning then
                                    first_reasoning = true
                                    pa.log("model.chat.first_reasoning")
                                end
                                thoughts[#thoughts + 1] = delta.reasoning_content
                                if chat.thinking then
                                    if streamed_kind == "content" then
                                        pa.emit("")
                                    end
                                    local prefix = (streamed_kind ~= "reasoning" or quote_start)
                                            and delta.reasoning_content:sub(1, 1) ~= "\n"
                                            and "> "
                                        or ""
                                    pa.emit(prefix .. delta.reasoning_content:gsub("\n([^\n])", "\n> %1"), "append")
                                    quote_start = delta.reasoning_content:sub(-1) == "\n"
                                    streamed_kind = "reasoning"
                                end
                            end
                            if type(delta.content) == "string" and delta.content ~= "" then
                                if pa.profile and not first_content then
                                    first_content = true
                                    pa.log("model.chat.first_content")
                                end
                                contents[#contents + 1] = delta.content
                                if streamed_kind == "reasoning" then
                                    pa.emit("")
                                end
                                pa.emit(delta.content, "append")
                                streamed_kind = "content"
                            end
                            for _, tool in ipairs(dense(delta.tool_calls or {}, "chat stream tool calls")) do
                                local index = type(tool) == "table" and tool.index
                                assert(
                                    math.type(index) == "integer" and index >= 0 and index < chat.maximum_tool_calls,
                                    "invalid tool call index"
                                )
                                local call = calls[index + 1]
                                if not call then
                                    call = { id = "", type = "function", ["function"] = { name = "", arguments = "" } }
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
                                            #call["function"].arguments <= chat.maximum_tool_argument_bytes,
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
        )
        pa.log("model.http.status." .. status)
        assert(status >= 200 and status < 300, "model endpoint failed: HTTP " .. status)
        assert(done and finished and table.concat(fragments):match("^%s*$"), "chat stream ended early")
        pa.log("model.http.end")
        local reasoning = #thoughts > 0 and table.concat(thoughts) or nil
        local content = #contents > 0 and table.concat(contents) or nil
        assert(reasoning == nil or type(reasoning) == "string" and utf8.len(reasoning), "invalid reasoning")
        assert(content == nil or type(content) == "string" and utf8.len(content), "invalid response")

        local entries = dense(calls, "chat tool calls")
        assert(#entries <= chat.maximum_tool_calls, "tool call limit")
        local decoded_calls, tool_calls, ids = {}, {}, {}
        for index, entry in ipairs(entries) do
            local fn = type(entry) == "table" and entry["function"]
            local id = type(entry) == "table" and entry.id
            local name = type(fn) == "table" and fn.name
            local arguments = type(fn) == "table" and fn.arguments
            assert(type(id) == "string" and id ~= "" and utf8.len(id) and not ids[id], "invalid tool call")
            assert(name == "run_lua" and type(arguments) == "string", "invalid tool call")
            assert(#arguments <= chat.maximum_tool_argument_bytes, "tool arguments are too large")
            local decoded = decode(arguments)
            assert(type(decoded) == "table", "invalid tool arguments")
            for key in pairs(decoded) do
                assert(key == "code", "unknown tool argument")
            end
            assert(
                type(decoded.code) == "string"
                    and decoded.code ~= ""
                    and utf8.len(decoded.code)
                    and #decoded.code <= chat.maximum_tool_source_bytes,
                "invalid tool source"
            )
            ids[id] = true
            decoded_calls[index] = { id = id, code = decoded.code }
            tool_calls[index] = { id = id, type = "function", ["function"] = { name = name, arguments = arguments } }
        end

        if finished == "length" then
            pa.log("model.chat.length")
            error("chat completion was truncated", 0)
        end
        assert(finished == "stop" or finished == "tool_calls", "invalid tool completion")
        pa.log("model.chat.finish." .. finished)
        if #decoded_calls == 0 then
            assert(finished == "stop" and content and content ~= "", "chat completion has no response")
        end
        pa.log("model.chat.decoded")
        return {
            reasoning = reasoning,
            content = content,
            calls = decoded_calls,
            tool_calls = tool_calls,
        }
    end

    function api:rerank(query, passages)
        if #query > rerank.query_tokens and tokens(rerank, endpoints.rerank.tokenize, query) > rerank.query_tokens then
            return {}
        end
        local selected, source = {}, {}
        for index, passage in ipairs(passages) do
            local content = query .. "\n" .. passage
            if
                #content <= rerank.passage_tokens
                or tokens(rerank, endpoints.rerank.tokenize, content) <= rerank.passage_tokens
            then
                selected[#selected + 1], source[#source + 1] = passage, index
            end
        end
        if #selected == 0 then
            return {}
        end
        pa.log("model.rerank.begin")
        local ranked = post(rerank, endpoints.rerank.endpoint, {
            documents = selected,
            query = query,
            top_n = #selected,
        }).results
        pa.log("model.rerank.end")
        dense(ranked, "reranker results")
        assert(#ranked == #selected, "reranker response has the wrong count")
        local output, seen = {}, {}
        for _, entry in ipairs(ranked) do
            local index = type(entry) == "table" and math.tointeger(entry.index)
            assert(index and index >= 0 and index < #selected and not seen[index], "reranker index is invalid")
            assert(finite(entry.relevance_score), "reranker score is invalid")
            seen[index], output[#output + 1] = true, source[index + 1]
        end
        return output
    end

    return api
end
