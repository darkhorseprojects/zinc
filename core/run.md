# Run

## Context

| field        | value |
| ------------ | ----: |
| recent_bytes |  4096 |

```luau
local expected = require("@authority")
local Database = require("@database")
local circuitry = require("@circuitry")
local json = require("@json")

local recentBytes = assert(tonumber(document.Context.recent_bytes), "recent_bytes must be a number")
if recentBytes < 0 or recentBytes ~= math.floor(recentBytes) then error("recent_bytes must be a nonnegative integer") end

return function(authority)
    if authority ~= expected then error("Run requires execution authority") end
    local databases = Database(authority)
    local active = nil
    local references = {}

    local function answer(response)
        local last = response.output and response.output[#response.output]
        if not last or last.type ~= "message" or type(last.content) ~= "table" then return response end
        local text = {}
        for _, content in ipairs(last.content) do
            if content.type == "output_text" and type(content.text) == "string" then table.insert(text, content.text) end
        end
        return #text > 0 and table.concat(text) or response
    end

    local function create(config)
        if type(config) ~= "table" or type(config.name) ~= "string" or type(config.request) ~= "function" then
            error("Agent configuration requires name and request")
        end
        local function ask(request)
            json.encode(request)
            local parent = active
            local database = parent and databases.child() or databases.open(config.name)
            local run = database.nextRun()
            local requestSlice = database.append(run, "user", request)
            local reference = table.freeze({})
            local record = {database = database, child = parent ~= nil, parent = parent, result = nil, closed = false}
            references[reference] = record
            active = record
            local ok, failure = pcall(function()
                local frontier = {request}
                while true do
                    local snapshot = database.snapshot()
                    local current = database.run(run)
                    local excluded, currentIds = {}, {}
                    for _, slice in ipairs(current) do excluded[slice.idx] = true table.insert(currentIds, slice.idx) end
                    local recent = database.recent(snapshot, run, recentBytes)
                    for _, slice in ipairs(recent) do excluded[slice.idx] = true end
                    local query = json.encode(frontier)
                    local recalled = database.recall(query, snapshot, run, excluded)
                    local response, selected = config.request(current, recent, recalled)
                    if type(response) ~= "table" or type(response.output) ~= "table" then
                        error("provider response has no output array")
                    end
                    if type(selected) ~= "table" then error("provider selection has no Slice array") end
                    local responseSlice = database.append(run, config.name, response)
                    database.trail(responseSlice, selected)
                    frontier = {request, response}
                    for _, output in ipairs(response.output) do
                        if type(output) ~= "table" or type(output.type) ~= "string" then
                            error("provider output item is invalid")
                        end
                        if output.type == "function_call" then
                            if type(output.call_id) ~= "string" then error("function call has no call_id") end
                            local callOk, value
                            if output.name ~= "circuitry" then
                                callOk, value = false, "unsupported function: " .. tostring(output.name)
                            elseif type(output.arguments) ~= "string" then
                                callOk, value = false, "circuitry arguments must be JSON text"
                            else
                                local decoded, arguments = pcall(json.decode, output.arguments)
                                if not decoded or type(arguments) ~= "table" or type(arguments.document) ~= "string" then
                                    callOk, value = false, "circuitry requires a document string"
                                else
                                    callOk, value = pcall(circuitry.load, arguments.document)
                                end
                            end
                            local direct = callOk and json.encode(value) or tostring(value)
                            local item = {type = "function_call_output", call_id = output.call_id, output = direct}
                            database.append(run, "circuitry", item)
                            table.insert(frontier, item)
                        end
                    end
                    local last = response.output and response.output[#response.output]
                    if last and last.type == "message" then record.result = answer(response) return end
                end
            end)
            active = parent
            if not ok then
                if record.child then databases.discard(database) record.closed = true else database.close() end
                error(failure)
            end
            if not record.child then database.close() end
            return reference
        end

        local function owned(reference)
            local record = references[reference]
            if not record or record.closed then error("invalid Run reference") end
            return record
        end

        local function read(reference)
            return owned(reference).result
        end

        local function merge(reference)
            local record = owned(reference)
            if not record.child or not record.parent then error("only a child Run can be merged") end
            databases.merge(record.parent.database, record.database)
            record.closed = true
            record.parent.database.append(record.parent.database.nextRun(), "merge", {agent = config.name})
        end

        local function discard(reference)
            local record = owned(reference)
            if not record.child then error("only a child Run can be discarded") end
            databases.discard(record.database)
            record.closed = true
        end

        return table.freeze({name = config.name, ask = ask, read = read, merge = merge, discard = discard})
    end

    return create
end
```
