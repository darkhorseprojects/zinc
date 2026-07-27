# Run

## Context

| field        | value |
| ------------ | ----: |
| recent_bytes |  4096 |

```teal
local authority = require("@authority")
local json = authority:require("dkjson")
local database = require("@database")(authority)
local builder = require("@builder")
local recentBytes = assert(math.tointeger(tonumber(document.Context.recent_bytes)), "recent_bytes must be an integer")
if recentBytes < 0 then error("recent_bytes must be a nonnegative integer") end
local active, references = nil, {}

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
local function answer(response)
   local last = response.output and response.output[#response.output]
   if not last or last.type ~= "message" or type(last.content) ~= "table" then return response end
   local text = {}
   for _, item in ipairs(last.content) do if item.type == "output_text" and type(item.text) == "string" then text[#text + 1] = item.text end end
   return #text > 0 and table.concat(text) or response
end
local function searchText(value)
   local values = {}
   local function visit(item)
      if type(item) == "string" then values[#values + 1] = item elseif type(item) == "table" then for _, child in pairs(item) do visit(child) end end
   end
   visit(value); return table.concat(values, "\n")
end
local function invoke(output)
   if output.name ~= "circuitry" then return false, "unsupported function: " .. tostring(output.name) end
   if type(output.arguments) ~= "string" then return false, "circuitry arguments must be JSON text" end
   local ok, arguments = pcall(decode, output.arguments)
   if not ok or type(arguments) ~= "table" or type(arguments.document) ~= "string" then return false, "circuitry requires a document string" end
   return pcall(builder.execute, arguments.document, arguments.input)
end
local function context(state, frontier)
   local snapshot = database.snapshot()
   local current = database.run(state.id)
   local excluded = {}
   for _, item in ipairs(current) do excluded[item.idx] = true end
   local recent = database.recent(snapshot, state.id, recentBytes)
   for _, item in ipairs(recent) do excluded[item.idx] = true end
   return current, recent, database.recall(searchText(frontier), snapshot, state.id, excluded)
end
local function continueRun(state, config, request)
   local frontier = {request}
   while true do
      local current, recent, recalled = context(state, frontier)
      local response, selected = config.request(state.actor, current, recent, recalled)
      if type(response) ~= "table" or type(response.output) ~= "table" then error("provider response has no output array") end
      if type(selected) ~= "table" then error("provider selection has no Slice array") end
      local responseSlice = database.append(state.id, config.name, response)
      database.trail(responseSlice, selected)
      frontier = {request, response}
      for _, output in ipairs(response.output) do
         if type(output) ~= "table" or type(output.type) ~= "string" then error("provider output item is invalid") end
         if output.type == "function_call" then
            if type(output.call_id) ~= "string" then error("function call has no call_id") end
            local callOk, value = invoke(output)
            local item = {type = "function_call_output", call_id = output.call_id, output = callOk and encode(value) or tostring(value)}
            database.append(state.id, "circuitry", item)
            frontier[#frontier + 1] = item
         end
      end
      local last = response.output[#response.output]
      if last and last.type == "message" then state.result = answer(response); database.complete(state.id, state.result); return end
   end
end
local function cleanup(state)
   for _, child in ipairs(state.children) do
      if not child.closed then database.discard(child.id, state.id); child.closed = true end
   end
end
local function owned(agent, reference)
   local state = references[reference]
   if not state or state.agent ~= agent or state.closed then error("invalid Run reference") end
   return state
end
local function ask(agent, config, request, actor)
   encode(request)
   local parent = active
   actor = actor or (parent and parent.actor) or config.actor()
   if type(actor) ~= "string" or actor == "" then error("actor must be nonempty text") end
   local state = {agent = agent, id = database.newRun(parent and parent.id or nil, actor), actor = actor, parent = parent, result = nil, closed = false, children = {}}
   if parent then parent.children[#parent.children + 1] = state end
   database.append(state.id, "request", request)
   local reference = {}; references[reference] = state
   active = state
   local ok, failure = pcall(continueRun, state, config, request)
   active = parent
   cleanup(state)
   if not ok then database.fail(state.id, failure); error(failure) end
   return reference
end
local function merge(agent, reference)
   local state = owned(agent, reference)
   if not state.parent or active ~= state.parent then error("only a child Run can be merged by its parent") end
   database.merge(state.id, state.parent.id); state.closed = true
end
local function discard(agent, reference)
   local state = owned(agent, reference)
   if not state.parent or active ~= state.parent then error("only a child Run can be discarded by its parent") end
   database.discard(state.id, state.parent.id); state.closed = true
end
local function create(config)
   if type(config) ~= "table" or type(config.name) ~= "string" or type(config.request) ~= "function" or type(config.actor) ~= "function" then error("Agent configuration requires name, actor, and request") end
   local agent = {}
   agent.name = config.name
   agent.ask = function(request, actor) return ask(agent, config, request, actor) end
   agent.read = function(reference) return owned(agent, reference).result end
   agent.merge = function(reference) return merge(agent, reference) end
   agent.discard = function(reference) return discard(agent, reference) end
   return agent
end
return function(token)
   if token ~= authority then error("Run authority is required") end
   return create
end
```
