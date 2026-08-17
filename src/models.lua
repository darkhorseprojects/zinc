local curl = require("cURL.safe")
local json = require("dkjson")

local function encode(value)
    local source, failure = json.encode(value)
    assert(source, failure)
    return source
end

local function decode(source)
    assert(type(source) == "string", "JSON source must be text")
    local value, position, failure = json.decode(source, 1, json.null)
    assert(not failure and not source:sub(position):find("%S"), failure or "JSON has trailing data")
    return value
end

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local tool = {
    type = "function",
    ["function"] = {
        name = "run_lua",
        description = "Execute Lua with registered capabilities and return its result.",
        parameters = {
            type = "object",
            additionalProperties = false,
            required = { "code" },
            properties = { code = { type = "string" } },
        },
    },
}

local module = {}

function module.new(config, sse)
    assert(type(sse) == "table", "SSE parser is required")
    assert(config.metrics == nil or type(config.metrics) == "table", "model metrics must be a table")
    local maximum_request_bytes =
        assert(math.tointeger(config.max_model_request_bytes), "model request limit must be an integer")
    assert(maximum_request_bytes > 0, "model request limit must be positive")

    local function measure(use, seconds)
        if config.metrics then
            local values = config.metrics[use]
            if not values then
                values = {}
                config.metrics[use] = values
            end
            values[#values + 1] = seconds
        end
    end

    local function post_source(use, url, source)
        if #source > maximum_request_bytes then
            return nil, "model request exceeds configured byte limit"
        end
        local chunks = {}
        local handle, failure = curl.easy({
            url = url,
            customrequest = "POST",
            postfields = source,
            followlocation = false,
            httpheader = { "content-type: application/json", "accept: application/json" },
            writefunction = function(chunk)
                chunks[#chunks + 1] = chunk
                return #chunk
            end,
        })
        if not handle then
            return nil, tostring(failure)
        end
        local ok, problem = handle:perform()
        local status = handle:getinfo_response_code()
        measure(use, handle:getinfo_total_time())
        handle:close()
        if not ok then
            return nil, tostring(problem)
        end
        local body = table.concat(chunks)
        local parsed, response = pcall(decode, body)
        if status < 200 or status >= 300 then
            local detail = parsed
                and type(response) == "table"
                and (response.message or type(response.error) == "table" and response.error.message)
            return nil, detail and tostring(detail) or "model endpoint returned HTTP " .. status
        end
        return parsed and response or nil, parsed and nil or "invalid model JSON: " .. tostring(response)
    end

    local function post(use, url, value)
        return post_source(use, url, encode(value))
    end

    local api = { encode = encode, decode = decode, null = json.null }

    function api:chat(messages)
        local request = encode({
            model = config.chat.model,
            messages = messages,
            tools = { tool },
            tool_choice = "auto",
            parallel_tool_calls = false,
            stream = true,
        })
        if #request > maximum_request_bytes then
            return nil, "model request exceeds configured byte limit"
        end
        local parser = sse.new()
        local queue, head, tail_index = {}, 1, 0
        local failure, done, finish, active = nil, false, nil, true
        local calls, call_order = {}, {}
        local function push(event)
            tail_index = tail_index + 1
            queue[tail_index] = event
        end
        local function append(call, field, value)
            if value ~= nil and value ~= json.null then
                if type(value) ~= "string" then
                    failure = "chat tool delta is invalid"
                    return
                end
                call[field] = (call[field] or "") .. value
            end
        end
        local function accept(record)
            if record.data == "[DONE]" then
                done = true
                return
            end
            local ok, response = pcall(decode, record.data)
            if not ok then
                failure = "invalid chat event JSON: " .. tostring(response)
                return
            end
            if type(response.error) == "table" then
                failure = tostring(response.error.message or "chat provider error")
                return
            end
            local choice = type(response.choices) == "table" and response.choices[1]
            if not choice then
                return
            end
            if type(choice) ~= "table" or type(choice.delta) ~= "table" then
                failure = "chat event has no delta"
                return
            end
            local delta = choice.delta
            local reasoning = delta.reasoning_content or delta.reasoning
            if reasoning ~= nil and reasoning ~= json.null then
                if type(reasoning) ~= "string" then
                    failure = "chat reasoning delta is invalid"
                    return
                elseif reasoning ~= "" then
                    push({ type = "reasoning", text = reasoning })
                end
            end
            if delta.content ~= nil and delta.content ~= json.null then
                if type(delta.content) ~= "string" then
                    failure = "chat content delta is invalid"
                    return
                elseif delta.content ~= "" then
                    push({ type = "response", text = delta.content })
                end
            end
            if delta.tool_calls ~= nil and delta.tool_calls ~= json.null then
                if type(delta.tool_calls) ~= "table" then
                    failure = "chat tool delta is invalid"
                    return
                end
                for _, value in ipairs(delta.tool_calls) do
                    local fn = type(value) == "table" and value["function"]
                    local index = type(value) == "table" and math.tointeger(value.index)
                    if not index or index < 0 or fn ~= nil and type(fn) ~= "table" then
                        failure = "chat tool delta is invalid"
                        return
                    end
                    local call = calls[index]
                    if not call then
                        call = { index = index }
                        calls[index] = call
                        call_order[#call_order + 1] = index
                    end
                    append(call, "id", value.id)
                    append(call, "name", fn and fn.name)
                    append(call, "arguments", fn and fn.arguments)
                    if failure then
                        return
                    end
                    push({
                        type = "tool",
                        id = value.id ~= json.null and value.id or nil,
                        name = fn and fn.name ~= json.null and fn.name or nil,
                        arguments = fn and fn.arguments ~= json.null and fn.arguments or nil,
                    })
                end
            end
            if choice.finish_reason ~= nil and choice.finish_reason ~= json.null then
                if finish or type(choice.finish_reason) ~= "string" or choice.finish_reason == "" then
                    failure = finish and "chat returned multiple finish reasons" or "chat finish reason is invalid"
                    return
                end
                finish = choice.finish_reason
            end
        end

        local easy, problem = curl.easy({
            url = config.chat.endpoint,
            customrequest = "POST",
            postfields = request,
            followlocation = false,
            httpheader = { "content-type: application/json", "accept: text/event-stream" },
            writefunction = function(chunk)
                local ok, records = pcall(parser.push, parser, chunk)
                if not ok then
                    failure = tostring(records)
                    return 0
                end
                for _, record in ipairs(records) do
                    accept(record)
                    if failure then
                        return 0
                    end
                end
                return #chunk
            end,
        })
        if not easy then
            return nil, tostring(problem)
        end
        local multi = assert(curl.multi())
        assert(multi:add_handle(easy))
        local ended = false
        local function close()
            if active then
                active = false
                pcall(multi.remove_handle, multi, easy)
                easy:close()
                multi:close()
            end
        end
        local function complete()
            local ok, records = pcall(parser.finish, parser)
            if not ok then
                failure = tostring(records)
            else
                for _, record in ipairs(records) do
                    accept(record)
                end
            end
            local status = easy:getinfo_response_code()
            measure("chat", easy:getinfo_total_time())
            if not failure and (status < 200 or status >= 300) then
                failure = "model endpoint returned HTTP " .. status
            elseif not failure and not done then
                failure = "chat stream ended without [DONE]"
            elseif not failure and not finish then
                failure = "chat stream ended without a finish reason"
            end
            if not failure then
                local completed = {}
                table.sort(call_order)
                for _, index in ipairs(call_order) do
                    local call = calls[index]
                    if not call.id or call.id == "" or not call.name or call.name == "" or call.arguments == nil then
                        failure = "chat tool call is incomplete"
                        break
                    end
                    completed[#completed + 1] = { id = call.id, name = call.name, arguments = call.arguments }
                end
                if not failure then
                    push({ type = "finish", reason = finish, tool_calls = completed })
                end
            end
            ended = true
            close()
        end
        local function pump()
            while head > tail_index and not ended and not failure do
                local running, perform_failure = multi:perform()
                if running == nil then
                    failure = tostring(perform_failure)
                elseif running == 0 then
                    local completed, ok, transfer_failure = multi:info_read()
                    if completed and not ok then
                        failure = tostring(transfer_failure)
                    end
                    complete()
                elseif head > tail_index then
                    local ready, wait_failure = multi:wait(1000)
                    if ready == nil then
                        failure = tostring(wait_failure)
                    end
                end
            end
            if failure then
                close()
            end
        end
        return function()
            if head > tail_index then
                pump()
            end
            if head <= tail_index then
                local event = queue[head]
                queue[head], head = nil, head + 1
                return event
            elseif failure then
                local value = failure
                failure = nil
                return nil, value
            end
        end
    end

    function api:propose(request)
        local response, failure = post("propose", config.propose.endpoint, request)
        if not response then
            return nil, failure
        end
        if type(response.terms) ~= "table" then
            return nil, "proposal response is invalid"
        end
        if #response.terms > request.maximum_terms then
            return nil, "proposal response exceeds the requested term count"
        end
        local result, seen = {}, {}
        for _, term in ipairs(response.terms) do
            if type(term) ~= "string" or term == "" or seen[term] then
                return nil, "proposal term is invalid"
            end
            seen[term] = true
            result[#result + 1] = term
        end
        return result
    end

    function api:rerank(query, passages)
        if #passages == 0 then
            return {}, 0
        end
        local prefix = '{"documents":['
        local middle = '],"model":' .. encode(config.rerank.model) .. ',"query":' .. encode(query) .. ',"top_n":'
        local suffix = "}"
        local documents, document_bytes = {}, 0
        for _, passage in ipairs(passages) do
            local encoded = encode(passage)
            local count = #documents + 1
            local projected = #prefix + document_bytes + #encoded + #documents + #middle + #tostring(count) + #suffix
            if projected > maximum_request_bytes then
                break
            end
            documents[count] = encoded
            document_bytes = document_bytes + #encoded
        end
        if #documents == 0 then
            return nil, "first reranker passage exceeds the request byte budget"
        end
        local source = prefix .. table.concat(documents, ",") .. middle .. #documents .. suffix
        local response, failure = post_source("rerank", config.rerank.endpoint, source)
        if not response then
            return nil, failure
        end
        if type(response.results) ~= "table" or #response.results ~= #documents then
            return nil, "reranker response has the wrong count"
        end
        local result, seen = {}, {}
        for _, item in ipairs(response.results) do
            local index = type(item) == "table" and math.tointeger(item.index)
            local score = type(item) == "table" and item.relevance_score
            if not index or index < 0 or index >= #documents or not finite(score) or seen[index] then
                return nil, "reranker item is invalid"
            end
            seen[index] = true
            result[#result + 1] = { index = index + 1, score = score }
        end
        return result, #documents
    end

    return api
end

return module
