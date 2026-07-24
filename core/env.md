# Environment

## Guide

Use configured files, HTTP, and shell access for machine actions. Check returned status and errors before
claiming success.

## Files

| root | access     |
| ---- | ---------- |
| .    | read-write |

## HTTP

| origin                 |
| ---------------------- |
| http://127.0.0.1:30000 |

## Commands

### Allow

### Deny

- `git push`
- `git reset`
- `git clean`
- `deno publish`

## Shells

| system  | command        | arguments                                             |
| ------- | -------------- | ----------------------------------------------------- |
| linux   | /bin/sh        | ["-c"]                                                |
| darwin  | /bin/sh        | ["-c"]                                                |
| windows | powershell.exe | ["-NoLogo","-NoProfile","-NonInteractive","-Command"] |

## Variables

| system  | name        |
| ------- | ----------- |
| all     | PATH        |
| linux   | HOME        |
| darwin  | HOME        |
| windows | USERPROFILE |
| windows | SYSTEMROOT  |
| windows | TEMP        |

```luau
local fs = require("@fs")
local http = require("@http")
local process = require("@process")
local system = require("@system")
local json = require("@json")

local platform = system.platform()
local roots = {}
for _, row in ipairs(document.Files.rows) do
    if row.access ~= "read" and row.access ~= "read-write" then error("file access must be read or read-write") end
    if row.root == "" then error("file root cannot be empty") end
    table.insert(roots, {path = fs.realpath(fs.resolve(row.root)), write = row.access == "read-write"})
end
if #roots == 0 then error("Environment requires at least one file root") end

local function within(path, root)
    return path == root or string.sub(path, 1, #root + 1) == root .. "/"
end

local function locate(path, writing)
    if type(path) ~= "string" then error("path must be a string") end
    local candidate = fs.resolve(path)
    local present = fs.exists(candidate)
    local canonical = present and fs.realpath(candidate) or candidate
    local parent = not present and writing and fs.realpath(fs.resolve(candidate, "..")) or nil
    for _, root in ipairs(roots) do
        local safe = within(canonical, root.path) and (parent == nil or within(parent, root.path))
        if safe and (not writing or root.write) then return canonical end
    end
    error("path is outside configured file roots")
end

local files = table.freeze({
    read = function(path) return fs.read(locate(path, false)) end,
    write = function(path, value) return fs.write(locate(path, true), value) end,
    list = function(path) return fs.list(locate(path, false)) end,
    remove = function(path) return fs.remove(locate(path, true), true) end,
})

local origins = {}
for _, row in ipairs(document.HTTP.rows) do
    local origin = http.origin(row.origin)
    if origins[origin] then error("duplicate HTTP origin: " .. origin) end
    origins[origin] = true
end
local network = table.freeze({
    request = function(options)
        if not origins[http.origin(options.url)] then error("HTTP origin is not configured") end
        return http.request(options)
    end,
})

local function headers(section)
    local result = {}
    for _, item in ipairs(section.items or {}) do
        local value = string.match(item.text, "^`(.*)`$") or item.text
        if value == "" then error("command header cannot be empty") end
        table.insert(result, value)
    end
    return result
end
local allow = headers(document.Commands.Allow)
local deny = headers(document.Commands.Deny)
local function matches(command, header)
    return command == header or string.sub(command, 1, #header + 1) == header .. " "
end

local shell
for _, row in ipairs(document.Shells.rows) do
    if row.system == platform then
        if shell then error("duplicate shell for " .. platform) end
        if row.command == "" then error("shell command cannot be empty") end
        shell = row
    end
end
if not shell then error("no shell is configured for " .. platform) end
local shellArguments = json.decode(shell.arguments)
if type(shellArguments) ~= "table" then error("shell arguments must be a JSON array") end
for _, argument in ipairs(shellArguments) do if type(argument) ~= "string" then error("shell arguments must be text") end end
local environment, variableNames = {}, {}
for _, row in ipairs(document.Variables.rows) do
    if row.system == "all" or row.system == platform then
        if row.name == "" then error("environment variable name cannot be empty") end
        if variableNames[row.name] then error("duplicate environment variable: " .. row.name) end
        variableNames[row.name] = true
        local value = system.getenv(row.name)
        if value ~= json.null then environment[row.name] = value end
    end
end

local function run(command)
    if type(command) ~= "string" then error("command must be a string") end
    command = string.match(command, "^%s*(.-)%s*$")
    for _, header in ipairs(deny) do if matches(command, header) then error("command header is denied") end end
    if #allow > 0 then
        local accepted = false
        for _, header in ipairs(allow) do if matches(command, header) then accepted = true break end end
        if not accepted then error("command header is not allowed") end
    end
    local arguments = table.clone(shellArguments)
    table.insert(arguments, command)
    return process.run({command = shell.command, arguments = arguments, directory = system.cwd(), environment = environment})
end

return table.freeze({guide = document.Guide.text, files = files, http = network, shell = run})
```
