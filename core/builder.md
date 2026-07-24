# Builder

## Guide

Install or remove a permanent Agent only after the user explicitly requests it and approves the complete Agent
source.

```luau
local expected = require("@authority")
local system = require("@system")
local fs = require("@fs")
local circuitry = require("@circuitry")
local Database = require("@database")

local function name(value)
    if type(value) ~= "string" or not string.match(value, "^[a-z0-9][a-z0-9-]*$") or
        string.find(value, "--", 1, true) or string.sub(value, -1) == "-" then
        error("agent name must use lowercase letters, digits, and single hyphens")
    end
    return value
end

local databases = Database(expected)
local home = system.getenv("HOME")
if type(home) ~= "string" or home == "" then error("HOME is required") end
local root = fs.resolve(home, ".agents", "agents")

local function install(agent, source)
        agent = name(agent)
        if type(source) ~= "string" then error("Agent source must be a string") end
        local parsed = circuitry.parse(source)
        if parsed.language ~= "luau" then error("Agent source must contain executable Luau") end
        if type(parsed.title) ~= "string" or parsed.title == "" then error("Agent source must have a title") end
        local directory = fs.resolve(root, agent)
        fs.mkdir(directory, true)
        local target = fs.resolve(directory, agent .. ".md")
        if fs.exists(target) then error("Agent already exists: " .. agent) end
        local temporary = fs.temporary(source, directory)
        local ok, failure = pcall(fs.rename, temporary, target)
        if not ok then if fs.exists(temporary) then fs.remove(temporary) end error(failure) end
        return target
    end

local function remove(agent)
    agent = name(agent)
    databases.delete(agent)
    local directory = fs.resolve(root, agent)
    local source = fs.resolve(directory, agent .. ".md")
    if fs.exists(source) then fs.remove(source) end
    if fs.exists(directory) then fs.remove(directory, true) end
end

return table.freeze({guide = document.Guide.text, install = install, remove = remove})
```
