# Zinc

## Instructions

You are Zinc, a direct local Agent. Answer plainly and complete the requested work. You have one tool,
`circuitry`. Its argument is a complete executable Markdown document with Luau fences. Use it for machine
actions, inspect returned values, and report failures honestly.

## Provider

| field         | value                               |
| ------------- | ----------------------------------- |
| endpoint      | http://127.0.0.1:30000/v1/responses |
| model         | ternary-bonsai-27b                  |
| request_bytes | 32768                               |

```luau
local authority = require("@authority")
local http = require("@http")
local json = require("@json")
local environment = require("@env")
local builder = require("@builder")
local createAgent = require("@run")(authority)
local user = require("@user")

local endpoint = document.Provider.endpoint
local model = document.Provider.model
if type(endpoint) ~= "string" or http.origin(endpoint) == "null" then error("Provider endpoint is invalid") end
if type(model) ~= "string" or model == "" then error("Provider model cannot be empty") end
if type(user) ~= "table" then error("User identity must be a table") end
local requestBytes = assert(tonumber(document.Provider.request_bytes), "request_bytes must be a number")
if requestBytes < 1024 or requestBytes ~= math.floor(requestBytes) then error("request_bytes must be an integer >= 1024") end

local tool = table.freeze({
    type = "function",
    name = "circuitry",
    description = "Execute one complete Markdown document containing Luau and return its JSON value.",
    strict = true,
    parameters = table.freeze({
        type = "object",
        properties = table.freeze({
            document = table.freeze({type = "string", description = "Complete executable Markdown document."}),
        }),
        required = table.freeze({"document"}),
        additionalProperties = false,
    }),
})

local instructions = table.concat({document.Instructions.text, environment.guide, builder.guide}, "\n\n")

local prefix = '{"model":' .. json.encode(model) .. ',"instructions":' .. json.encode(instructions) ..
    ',"tools":' .. json.encode({tool}) .. ',"input":['
local suffix = "]}"

local function currentItems(current)
    local items = {{role = "user", content = "User identity: " .. json.encode(user)}}
    for _, slice in ipairs(current) do
        if slice.actor == "user" then
            table.insert(items, {role = "user", content = type(slice.value) == "string" and slice.value or json.encode(slice.value)})
        elseif slice.actor == "circuitry" then
            table.insert(items, slice.value)
        elseif type(slice.value) == "table" and type(slice.value.output) == "table" then
            for _, output in ipairs(slice.value.output) do table.insert(items, output) end
        end
    end
    return items
end

local function memoryItem(slice)
    return {role = "user", content = "Relevant memory: " .. json.encode({actor = slice.actor, value = slice.value})}
end

local function encodedBody(fragments)
    return prefix .. table.concat(fragments, ",") .. suffix
end

local function request(current, recent, recalled)
    if type(current) ~= "table" or type(recent) ~= "table" or type(recalled) ~= "table" then
        error("provider context must contain Slice arrays")
    end
    local mandatory, selected = {}, {}
    for _, item in ipairs(currentItems(current)) do table.insert(mandatory, json.encode(item)) end
    local currentIds = {}
    for _, slice in ipairs(current) do table.insert(currentIds, slice.idx) end
    local memory = {}
    for _, slice in ipairs(recent) do table.insert(memory, {idx = slice.idx, encoded = json.encode(memoryItem(slice))}) end
    local function fragments()
        local result = {}
        for _, item in ipairs(memory) do table.insert(result, item.encoded) end
        for _, item in ipairs(mandatory) do table.insert(result, item) end
        return result
    end
    while #encodedBody(fragments()) > requestBytes and #memory > 0 do table.remove(memory, 1) end
    if #encodedBody(fragments()) > requestBytes then error("mandatory provider request exceeds request_bytes") end
    for _, slice in ipairs(recalled) do
        local item = {idx = slice.idx, encoded = json.encode(memoryItem(slice))}
        table.insert(memory, item)
        if #encodedBody(fragments()) > requestBytes then table.remove(memory) end
    end
    local seen = {}
    for _, item in ipairs(memory) do
        if not seen[item.idx] then table.insert(selected, item.idx) seen[item.idx] = true end
    end
    for _, idx in ipairs(currentIds) do
        if not seen[idx] then table.insert(selected, idx) seen[idx] = true end
    end
    local encoded = encodedBody(fragments())
    local response = http.request({url = endpoint, method = "POST", headers = {["content-type"] = "application/json"}, body = encoded})
    if response.status < 200 or response.status >= 300 then error("provider returned HTTP " .. tostring(response.status)) end
    if type(response.body) ~= "string" or response.body == "" then error("provider returned an empty body") end
    local value = json.decode(response.body)
    if type(value) ~= "table" or type(value.output) ~= "table" then error("provider response has no output array") end
    return value, selected
end

return createAgent({name = "zinc", request = request})
```
