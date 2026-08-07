local curl = require("cURL.safe")
local json = require("dkjson")

local tool = {
    type = "function",
    ["function"] = {
        name = "run_lua",
        description = "Runs Lua. return sets the tool result. Available globals: args, require.",
        parameters = {
            type = "object",
            additionalProperties = false,
            required = {"code"},
            properties = {code = {type = "string"}},
        },
    },
}

local function encode(value)
    local text, failure = json.encode(value)
    if not text then error(failure) end
    return text
end

local function decode(source)
    local value, position, failure = json.decode(source, 1, json.null)
    if failure or source:sub(position):find("%S") then error(failure or "response has trailing data") end
    return value
end

return function(config)
    local function post(url, value)
        local chunks = {}
        local handle, failure = curl.easy({
            url = url,
            customrequest = "POST",
            postfields = encode(value),
            followlocation = false,
            httpheader = {"content-type: application/json", "accept: application/json"},
            writefunction = function(chunk) chunks[#chunks + 1] = chunk; return #chunk end,
        })
        if not handle then return nil, tostring(failure) end
        local ok, problem = handle:perform()
        local status = handle:getinfo_response_code()
        handle:close()
        if not ok then return nil, tostring(problem) end
        local body = table.concat(chunks)
        if status < 200 or status >= 300 then
            local decoded, parsed = pcall(decode, body)
            local detail
            if decoded and type(parsed) == "table" then
                detail = parsed.message
                if not detail and type(parsed.error) == "table" then detail = parsed.error.message end
            end
            return nil, detail and tostring(detail) or "llama.cpp returned HTTP " .. status
        end
        local decoded, parsed = pcall(decode, body)
        if not decoded then return nil, "invalid llama.cpp JSON: " .. tostring(parsed) end
        return parsed
    end

    local api = {}

    function api:chat(messages, instructions, memory)
        local input = {{role = "system", content = instructions .. "\n\n# Retrieved memory\n\n" .. memory}}
        for _, message in ipairs(messages) do input[#input + 1] = message end
        local response, failure = post(config.chat_endpoint, {
            model = config.chat_model,
            messages = input,
            tools = {tool},
            tool_choice = "auto",
            parallel_tool_calls = false,
        })
        if not response then return nil, failure end
        local choice = type(response.choices) == "table" and response.choices[1]
        if type(choice) ~= "table" or type(choice.message) ~= "table" then return nil, "llama.cpp chat response has no message" end
        if choice.message.tool_calls == json.null then choice.message.tool_calls = nil end
        if choice.message.content == json.null then choice.message.content = nil end
        return choice.message, choice.finish_reason
    end

    function api:embed(values, query)
        local input = {}
        for index, value in ipairs(values) do
            if type(value) ~= "string" then error("embedding input must be text") end
            input[index] = query and ("Instruct: Retrieve prior agent events that provide facts, decisions, results, or execution context useful for the current request.\nQuery: " .. value) or value
        end
        local response, failure = post(config.embedding_endpoint, {model = config.embedding_model, input = input, encoding_format = "float"})
        if not response then return nil, failure end
        if type(response.data) ~= "table" or #response.data ~= #values then return nil, "llama.cpp embedding response has the wrong count" end
        local result = {}
        for _, item in ipairs(response.data) do
            local index = type(item) == "table" and math.tointeger(item.index)
            if not index or index < 0 or index >= #values or type(item.embedding) ~= "table" or #item.embedding ~= 1024 then
                return nil, "llama.cpp embedding item is invalid"
            end
            result[index + 1] = item.embedding
        end
        return result
    end

    function api:rerank(query, documents)
        if #documents == 0 then return {} end
        local response, failure = post(config.rerank_endpoint, {
            model = config.rerank_model,
            query = query,
            documents = documents,
            instruct = "Rank prior agent events by how useful they are for answering the current request or continuing its work.",
            return_documents = false,
        })
        if not response then return nil, failure end
        local items = type(response.results) == "table" and response.results or response
        local result = {}
        for _, item in ipairs(items) do
            local index = type(item) == "table" and math.tointeger(item.index)
            if not index or index < 0 or index >= #documents or type(item.score or item.relevance_score) ~= "number" then return nil, "llama.cpp rerank item is invalid" end
            result[#result + 1] = {index = index + 1, score = item.score or item.relevance_score}
        end
        table.sort(result, function(a, b) return a.score == b.score and a.index < b.index or a.score > b.score end)
        return result
    end

    function api:arguments(call)
        local source = type(call) == "table" and type(call["function"]) == "table" and call["function"].arguments
        if type(source) ~= "string" then return nil, "function arguments are not JSON text" end
        local ok, value = pcall(decode, source)
        if not ok or type(value) ~= "table" then return nil, ok and "function arguments are invalid" or tostring(value) end
        return value
    end

    function api:toolOutput(value)
        if value == nil then return "" end
        if type(value) == "string" then return value end
        local ok, text = pcall(encode, value)
        if not ok then return nil, tostring(text) end
        return text
    end

    return api
end
