# Zinc

## Instructions

You are Zinc, one direct local Agent with durable memory. Answer plainly. Use the `circuitry` tool when machine work is needed, inspect its returned value, and report failures honestly.

## Provider

| field         | value                               |
| ------------- | ----------------------------------- |
| endpoint      | http://127.0.0.1:30000/v1/responses |
| model         | ternary-bonsai-27b                  |
| request_bytes | 32768                               |

```teal
local authority = require("@authority")
local json = authority:require("dkjson")
local environment = require("@env")
local builder = require("@builder")
local create = require("@run")(authority)

local endpoint = document.Provider.endpoint
local model = document.Provider.model
local requestBytes = assert(math.tointeger(tonumber(document.Provider.request_bytes)), "request_bytes must be an integer")
if type(endpoint) ~= "string" or endpoint == "" then error("Provider endpoint is invalid") end
if type(model) ~= "string" or model == "" then error("Provider model cannot be empty") end
if requestBytes < 1024 then error("request_bytes must be an integer >= 1024") end
local profile = environment.profile()

local function encode(value)
   local text, failure = json.encode(value)
   if not text then error(failure) end
   return text
end
local function decode(text)
   local value, _, failure = json.decode(text, 1, json.null)
   if failure then error(failure) end
   return value
end
local tool = {
   type = "function",
   name = "circuitry",
   description = "Execute one complete Markdown document under Zinc's Environment policy.",
   strict = true,
   parameters = {
      type = "object",
      properties = {
         document = {type = "string", description = "Complete executable Markdown document."},
         input = {type = "string", description = "Optional raw input for the document."},
      },
      required = {"document"},
      additionalProperties = false,
   },
}
local instructions = table.concat({document.Instructions.text, environment.guide, builder.guide}, "\n\n")
local function providerItem(slice)
   if slice.actor == "request" then
      return {role = "user", content = type(slice.value) == "string" and slice.value or encode(slice.value)}
   end
   if slice.actor == "circuitry" then return slice.value end
   if type(slice.value) == "table" and type(slice.value.output) == "table" then return slice.value.output end
   return {role = "user", content = "Run event: " .. encode(slice.value)}
end
local function memoryItem(slice)
   return {role = "user", content = "Relevant memory: " .. encode({actor = slice.actor, value = slice.value})}
end
local function body(actor, items)
   local input = {{role = "user", content = "Actor: " .. actor .. "\nProfile: " .. encode(profile)}}
   for _, item in ipairs(items) do input[#input + 1] = item.value end
   return encode({model = model, instructions = instructions, tools = {tool}, input = input})
end
local function request(actor, current, recent, recalled)
   if type(actor) ~= "string" or type(current) ~= "table" or type(recent) ~= "table" or type(recalled) ~= "table" then error("provider context is invalid") end
   local mandatory, memory = {}, {}
   for _, slice in ipairs(current) do
      local item = providerItem(slice)
      if item[1] and item[1].type then for _, output in ipairs(item) do mandatory[#mandatory + 1] = {idx = slice.idx, value = output} end
      else mandatory[#mandatory + 1] = {idx = slice.idx, value = item} end
   end
   for _, slice in ipairs(recent) do memory[#memory + 1] = {idx = slice.idx, value = memoryItem(slice)} end
   local function selectedItems()
      local result = {}
      for _, item in ipairs(memory) do result[#result + 1] = item end
      for _, item in ipairs(mandatory) do result[#result + 1] = item end
      return result
   end
   while #body(actor, selectedItems()) > requestBytes and #memory > 0 do table.remove(memory, 1) end
   if #body(actor, selectedItems()) > requestBytes then error("mandatory provider request exceeds request_bytes") end
   for _, slice in ipairs(recalled) do
      memory[#memory + 1] = {idx = slice.idx, value = memoryItem(slice)}
      if #body(actor, selectedItems()) > requestBytes then table.remove(memory) end
   end
   local selected, seen = {}, {}
   for _, item in ipairs(selectedItems()) do if not seen[item.idx] then selected[#selected + 1] = item.idx; seen[item.idx] = true end end
   local response = environment.http.request({url = endpoint, method = "POST", headers = {["content-type"] = "application/json"}, body = body(actor, selectedItems())})
   if response.status < 200 or response.status >= 300 then error("provider returned HTTP " .. response.status) end
   if type(response.body) ~= "string" or response.body == "" then error("provider returned an empty body") end
   local value = decode(response.body)
   if type(value) ~= "table" or type(value.output) ~= "table" then error("provider response has no output array") end
   return value, selected
end

local agent = create({name = "zinc", actor = function() return profile.username end, request = request})
if input ~= nil then
   local actor = arguments[1] or profile.username
   local run = agent.ask(input, actor)
   local result = agent.read(run)
   return type(result) == "string" and result or encode(result)
end
return agent
```
