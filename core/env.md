# Environment

## Guide

Use `require("@env")` from generated tools. Its `files`, `http`, and `shell` functions enforce this document's policy. Treat errors and nonzero statuses as failures.

## Files

| root   | access     |
| ------ | ---------- |
| .      | read-write |

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

```teal
local authority = require("@authority")
local lfs = authority:require("lfs")
local curl = authority:require("cURL.safe")
local io = authority.io
local circuitry = require("@circuitry")
local separator = authority.package.config:sub(1, 1)
local state = circuitry.agent("zinc").state

local function normalize(path)
   if type(path) ~= "string" or path == "" then error("path must be nonempty text") end
   if separator ~= "/" then path = path:gsub("\\", "/") end
   if path:sub(1, 1) ~= "/" then path = lfs.currentdir():gsub("\\", "/") .. "/" .. path end
   local parts = {}
   for part in path:gmatch("[^/]+") do
      if part == ".." then if #parts == 0 then error("path escapes its root") end; table.remove(parts)
      elseif part ~= "." and part ~= "" then parts[#parts + 1] = part end
   end
   return "/" .. table.concat(parts, "/")
end
local function noSymlink(path)
   local prefix = ""
   for part in path:gmatch("[^/]+") do
      prefix = prefix .. "/" .. part
      local attributes = lfs.symlinkattributes(prefix)
      if attributes and attributes.mode == "link" then error("symbolic links are outside Environment policy") end
      if not attributes then return end
   end
end
local function within(path, root)
   return path == root.path or path:sub(1, #root.path + 1) == root.path .. "/"
end
local roots = {}
for _, row in ipairs(document.Files.rows) do
   if row.access ~= "read" and row.access ~= "read-write" then error("file access must be read or read-write") end
   local path = normalize(row.root == "$STATE" and state or row.root)
   noSymlink(path)
   if not lfs.attributes(path) then error("configured file root does not exist: " .. path) end
   roots[#roots + 1] = {path = path, write = row.access == "read-write"}
end
local function checked(path, writing)
   path = normalize(path); noSymlink(path)
   for _, root in ipairs(roots) do if within(path, root) and (not writing or root.write) then return path end end
   error("path is outside configured file roots")
end
local function read(path)
   local file, failure = io.open(checked(path, false), "rb")
   if not file then error(failure) end
   local value = file:read("a"); file:close(); return value
end
local function write(path, value)
   if type(value) ~= "string" then error("file value must be a string") end
   local file, failure = io.open(checked(path, true), "wb")
   if not file then error(failure) end
   local ok, message = file:write(value); local closed = file:close()
   if not ok or not closed then error(message or "file write failed") end
end
local files = {
   read = read,
   write = write,
   list = function(path)
      local values = {}
      for name in lfs.dir(checked(path, false)) do if name ~= "." and name ~= ".." then values[#values + 1] = name end end
      table.sort(values); return values
   end,
   mkdir = function(path) local ok, failure = lfs.mkdir(checked(path, true)); if not ok then error(failure) end end,
   remove = function(path) local ok, failure = authority.os.remove(checked(path, true)); if not ok then error(failure) end end,
}

local function origin(url)
   if type(url) ~= "string" then error("URL must be text") end
   local value = url:match("^([%a][%w+.-]*://[^/]+)")
   if not value then error("URL has no origin") end
   return value:lower()
end
local origins = {}
for _, row in ipairs(document.HTTP.rows) do
   local value = origin(row.origin)
   if origins[value] then error("duplicate HTTP origin: " .. value) end
   origins[value] = true
end
local function request(options)
   if type(options) ~= "table" or not origins[origin(options.url)] then error("HTTP origin is not configured") end
   local chunks, headers = {}, {}
   for name, value in pairs(options.headers or {}) do headers[#headers + 1] = name .. ": " .. value end
   local handle, failure = curl.easy({
      url = options.url, customrequest = options.method or "GET", httpheader = headers,
      postfields = options.body, timeout = options.timeout or 30,
      writefunction = function(chunk) chunks[#chunks + 1] = chunk; return #chunk end,
   })
   if not handle then error(failure) end
   local ok, message = handle:perform()
   local status = handle:getinfo_response_code()
   handle:close()
   if not ok then error(message) end
   return {status = status, body = table.concat(chunks)}
end

local function headers(section)
   local result = {}
   for _, value in ipairs(section.items or {}) do
      value = value:match("^`(.*)`$") or value
      if value == "" then error("command header cannot be empty") end
      result[#result + 1] = value
   end
   return result
end
local allow, deny = headers(document.Commands.Allow), headers(document.Commands.Deny)
local function matches(command, header)
   return command == header or command:sub(1, #header + 1) == header .. " "
end
local function shell(command)
   if type(command) ~= "string" then error("command must be text") end
   command = command:match("^%s*(.-)%s*$")
   for _, header in ipairs(deny) do if matches(command, header) then error("command header is denied") end end
   if #allow > 0 then local accepted = false; for _, header in ipairs(allow) do if matches(command, header) then accepted = true end end; if not accepted then error("command header is not allowed") end end
   local process, failure = io.popen(command .. " 2>&1", "r")
   if not process then error(failure) end
   local output = process:read("a")
   local ok, _, code = process:close()
   return {code = ok and 0 or code, output = output}
end
local function profile()
   local file, failure = io.open(state .. separator .. "user.md", "rb")
   if not file then error(failure) end
   local parsed = circuitry.parse(file:read("a")); file:close()
   if type(parsed.username) ~= "string" or parsed.username == "" then error("user.md username must be nonempty text") end
   return parsed
end
return {guide = document.Guide.text, files = files, http = {request = request}, shell = shell, profile = profile}
```
