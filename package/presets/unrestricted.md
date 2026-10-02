# Operations

Filesystem roots, HTTP targets, and absolute process executables are arguments. Relative filesystem roots resolve from the package; `.` selects that directory. `./` is optional before a file path. HTTP paths begin with `/`; headers are a table. Process arguments are a string array; input is stdin.

```lua
local pa = require("pa")
local capability = {
    __tostring = function(self)
        return table.concat(self, "\n")
    end,
    __call = function(self, value, tools)
        local fn = assert(rawget(self, value.action), "invalid capability action")
        assert(type(fn) == "function", "invalid capability action")
        local count = debug.getinfo(fn, "u").nparams - 1
        assert(value.arguments.n == count, "invalid capability arguments")
        return fn(tools, table.unpack(value.arguments, 1, count))
    end,
}
local preset = setmetatable({}, {
    document = pa.document(),
    targets = { "unrestricted", "configured", "empty" },
    __tostring = function(self)
        local names, lines = {}, { tostring(getmetatable(self).document) }
        for name in pairs(self) do
            names[#names + 1] = name
        end
        table.sort(names)
        for _, name in ipairs(names) do
            lines[#lines + 1] = tostring(self[name])
        end
        return table.concat(lines, "\n")
    end,
})
```

## Filesystem

```lua
local function open(root, path)
    assert(type(root) == "string" and root ~= "" and type(path) == "string", "invalid filesystem call")
    root = root:gsub("^%./", "")
    if root == "" or root == "." then
        root = nil
    end
    return pa.fs(root), path:gsub("^%./", "")
end
preset.fs = setmetatable({
    "self.fs.read(root,path) -> string (UTF-8 file text)",
    [[self.fs.write(root,path,text) -> "written"]],
    read = function(_, root, path)
        local directory <close>, filename = open(root, path)
        local data = directory:read(filename)
        assert(utf8.len(data), "file is not UTF-8")
        return data
    end,
    write = function(_, root, path, text)
        local directory <close>, filename = open(root, path)
        assert(type(text) == "string" and utf8.len(text), "invalid text")
        directory:write(filename, text)
        return "written"
    end,
}, capability)
```

## HTTP

```lua
preset.http = setmetatable({
    "self.http.request(method,origin,path,body,headers) -> {status,body}",
    request = function(_, method, origin, path, body, headers)
        assert(
            type(method) == "string" and type(origin) == "string" and type(path) == "string" and type(body) == "string",
            "invalid HTTP call"
        )
        local status, response = pa.http(origin, method, path, body, headers or {})
        assert(utf8.len(response), "HTTP body is not UTF-8")
        return { status = status, body = response }
    end,
}, capability)
```

## Process

```lua
preset.process = setmetatable({
    "self.process.run(executable,arguments,input) -> {code,stdout,stderr}",
    run = function(_, executable, arguments, input)
        input = input or ""
        assert(type(executable) == "string" and type(arguments) == "table", "invalid process call")
        assert(type(input) == "string", "invalid process input")
        for _, argument in ipairs(arguments) do
            assert(type(argument) == "string", "invalid process arguments")
        end
        local code, stdout, stderr = pa.process(executable, arguments, input)
        assert(utf8.len(stdout) and utf8.len(stderr), "process output is not UTF-8")
        return { code = code, stdout = stdout, stderr = stderr }
    end,
}, capability)
return preset
```
