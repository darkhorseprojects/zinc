# Operations

Filesystem paths are relative to their named roots. Search covers the whole named root. `./` is optional before a file path. HTTP calls take a string body and a headers table.

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
    targets = { "configured", "empty" },
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

local function relative(path)
    assert(type(path) == "string" and not path:find("\\", 1, true), "invalid path")
    if path == "." then
        return ""
    end
    path = path:gsub("^%./", "")
    assert(path:sub(1, 1) ~= "/" and path:sub(-1) ~= "/" and not path:find("//", 1, true), "invalid path")
    for part in path:gmatch("[^/]+") do
        assert(part ~= "." and part ~= "..", "invalid path")
    end
    return path
end
```

## Filesystem

```lua
preset.fs = setmetatable({
    "self.fs.read(root,path) -> string (UTF-8 file text)",
    [[self.fs.write(root,path,text) -> "written"]],
    read = function(tools, root, path)
        root = assert(tools.roots[root], "unknown root")
        path = relative(path)
        local directory <close> = pa.fs(root)
        local data = directory:read(path)
        assert(utf8.len(data), "file is not UTF-8")
        return data
    end,
    write = function(tools, root, path, text)
        root = assert(tools.roots[root], "unknown root")
        path = relative(path)
        local directory <close> = pa.fs(root)
        assert(type(text) == "string" and utf8.len(text), "invalid text")
        directory:write(path, text)
        return "written"
    end,
}, capability)
```

## HTTP

```lua
preset.http = setmetatable({
    "self.http.call(action,body,headers) -> {status,body}",
    call = function(tools, action, body, headers)
        local selected = assert(tools.actions[action], "unknown HTTP action")
        assert(type(body) == "string", "invalid HTTP body")
        local status, response = pa.http(selected.origin, selected.method, selected.path, body, headers or {})
        assert(utf8.len(response), "HTTP body is not UTF-8")
        return { status = status, body = response }
    end,
}, capability)
```

## Search

```lua
local function search(tools, root, query)
    root = assert(tools.roots[root], "unknown root")
    local command = { "--no-follow" }
    if query then
        command[#command + 1] = "--"
        command[#command + 1] = query
    else
        command[#command + 1] = "--files"
        command[#command + 1] = "--"
    end
    command[#command + 1] = root
    local code, stdout, stderr = pa.process(assert(tools.search, "search executable is not configured"), command, "")
    assert((code == 0 or query and code == 1) and utf8.len(stdout), stderr)
    return stdout
end
preset.search = setmetatable({
    "self.search.text(root,query) -> string (matching lines)",
    "self.search.files(root) -> string (file paths)",
    text = function(tools, root, query)
        assert(type(query) == "string", "invalid search")
        return search(tools, root, query)
    end,
    files = function(tools, root)
        return search(tools, root)
    end,
}, capability)
return preset
```
