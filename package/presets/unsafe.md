# Unsafe

Generated Lua may select filesystem roots, HTTP origins and methods, and absolute process executables. These adapters impose only Zinc's byte wire format.

```lua
local json = require("src.json")
local pa = require("pa")

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
            prompt = "JSON fields: root, operation, path, optional data. Root and path are unrestricted.",
            call = function(input)
                local value = json.object(input, { root = true, operation = true, path = true, data = true })
                assert(type(value.root) == "string" and value.root ~= "", "invalid root")
                assert(type(value.path) == "string" and value.path ~= "", "invalid path")
                local root = pa.fs(value.root)
                if value.operation == "read" then
                    assert(value.data == nil, "invalid read")
                    local data = root.read(value.path)
                    assert(utf8.len(data), "file is not UTF-8")
                    return json.encode({ data = data })
                end
                assert(
                    value.operation == "write" and type(value.data) == "string" and utf8.len(value.data),
                    "invalid write"
                )
                root.write(value.path, value.data)
                return '{"written":true}'
            end,
        },
        http = {
            prompt = "JSON fields: origin, method, path, body, headers. All PA-supported origins and methods are available.",
            call = function(input)
                local value =
                    json.object(input, { origin = true, method = true, path = true, body = true, headers = true })
                assert(type(value.origin) == "string" and value.origin ~= "", "invalid origin")
                assert(type(value.method) == "string" and value.method ~= "", "invalid method")
                assert(type(value.path) == "string" and type(value.body) == "string", "invalid HTTP request")
                local status, body = pa.http(value.origin, value.method, value.path, value.body, headers(value.headers))
                assert(utf8.len(body), "response is not UTF-8")
                return json.encode({ status = status, body = body })
            end,
        },
        process = {
            prompt = "JSON fields: executable, arguments, optional input. The absolute executable is unrestricted.",
            call = function(input)
                local value = json.object(input, { executable = true, arguments = true, input = true })
                assert(type(value.executable) == "string" and value.executable ~= "", "invalid executable")
                assert(type(value.arguments) == "table", "invalid arguments")
                local count = 0
                for key, argument in pairs(value.arguments) do
                    assert(
                        math.type(key) == "integer" and key >= 1 and key <= #value.arguments,
                        "arguments must be dense"
                    )
                    assert(type(argument) == "string", "arguments must be strings")
                    count = count + 1
                end
                assert(
                    count == #value.arguments and (value.input == nil or type(value.input) == "string"),
                    "invalid process request"
                )
                local code, stdout, stderr = pa.process(value.executable, value.arguments, value.input or "")
                assert(utf8.len(stdout) and utf8.len(stderr), "process output is not UTF-8")
                return json.encode({ code = code, stdout = stdout, stderr = stderr })
            end,
        },
    },
}
```
