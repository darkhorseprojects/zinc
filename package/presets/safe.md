# Safe

Generated Lua may access the dedicated `workspace` directory, send GET or POST requests to `http://127.0.0.1:8000`, and search workspace files with `/usr/bin/rg`. Edit the literal member table to replace, rename, remove, or add trusted wrappers.

```lua
local json = require("src.json")
local pa = require("pa")
local root = pa.fs("workspace")

local function path(value)
    assert(type(value) == "string" and value ~= "" and utf8.len(value), "invalid path")
    assert(value:sub(1, 1) ~= "/" and not value:find("\\", 1, true), "invalid path")
    for part in value:gmatch("[^/]+") do
        assert(part ~= "." and part ~= "..", "invalid path")
    end
    assert(not value:find("//", 1, true) and value:sub(-1) ~= "/", "invalid path")
    return value
end

local function headers(value)
    assert(type(value) == "table", "headers must be an object")
    for key, item in pairs(value) do
        assert(
            type(key) == "string" and type(item) == "string" and utf8.len(key) and utf8.len(item),
            "headers must contain UTF-8 strings"
        )
    end
    return value
end

return {
    document = pa.document(),
    members = {
        fs = {
            prompt = 'JSON fields: operation, path, optional data. Example: return self.fs([=[{"operation":"read","path":"README.md"}]=]).',
            call = function(input)
                local value = json.object(input, { operation = true, path = true, data = true })
                local file = path(value.path)
                if value.operation == "read" then
                    assert(value.data == nil, "invalid read")
                    local data = root.read(file)
                    assert(utf8.len(data), "file is not UTF-8")
                    return json.encode({ data = data })
                end
                assert(
                    value.operation == "write" and type(value.data) == "string" and utf8.len(value.data),
                    "invalid write"
                )
                root.write(file, value.data)
                return '{"written":true}'
            end,
        },
        http = {
            prompt = 'JSON fields: method, path, body, headers. Example: return self.http([=[{"method":"GET","path":"/health","body":"","headers":{}}]=]).',
            call = function(input)
                local value = json.object(input, { method = true, path = true, body = true, headers = true })
                assert(value.method == "GET" or value.method == "POST", "method is denied")
                assert(type(value.path) == "string" and type(value.body) == "string", "invalid HTTP request")
                local status, body =
                    pa.http("http://127.0.0.1:8000", value.method, value.path, value.body, headers(value.headers))
                assert(utf8.len(body), "response is not UTF-8")
                return json.encode({ status = status, body = body })
            end,
        },
        process = {
            prompt = 'JSON fields: query, paths. Example: return self.process([=[{"query":"event","paths":["README.md"]}]=]).',
            call = function(input)
                local value = json.object(input, { query = true, paths = true })
                assert(type(value.query) == "string" and value.query ~= "", "invalid query")
                assert(type(value.paths) == "table" and #value.paths > 0, "invalid paths")
                local arguments, count = { "--", value.query }, 0
                for key, item in pairs(value.paths) do
                    assert(math.type(key) == "integer" and key >= 1 and key <= #value.paths, "paths must be dense")
                    assert(type(item) == "string", "paths must be strings")
                    count = count + 1
                end
                assert(count == #value.paths, "paths must be dense")
                for _, item in ipairs(value.paths) do
                    arguments[#arguments + 1] = path(item)
                end
                local code, stdout, stderr = pa.process("/usr/bin/rg", arguments, "")
                assert(utf8.len(stdout) and utf8.len(stderr), "process output is not UTF-8")
                return json.encode({ code = code, stdout = stdout, stderr = stderr })
            end,
        },
    },
}
```
