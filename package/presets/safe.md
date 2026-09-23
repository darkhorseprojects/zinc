# Operations

Filesystem paths and search directories are relative to their named roots.

```lua
local pa = require("pa")
local home = assert(os.getenv("HOME"), "HOME is unavailable")

local roots = {
    home = {
        path = home,
        handle = pa.fs(home),
        operations = { "read", "write", "search" },
    },
}

local actions = {
    model_health = { method = "GET", origin = "http://127.0.0.1:8000", path = "/health" },
    model_models = { method = "GET", origin = "http://127.0.0.1:8000", path = "/v1/models" },
}

local function relative(path)
    assert(type(path) == "string" and not path:find("\\", 1, true), "invalid path")
    assert(path:sub(1, 1) ~= "/" and path:sub(-1) ~= "/" and not path:find("//", 1, true), "invalid path")
    for part in path:gmatch("[^/]+") do
        assert(part ~= "." and part ~= "..", "invalid path")
    end
    return path
end

return {
    document = pa.document(),
    targets = { "safe", "no-host" },
    whitelist = { roots = roots, actions = actions },
    members = {
        fs = {
            usage = {
                [[self.fs.read(root,path) -> string
local text = self.fs.read("home","PATH")
return text]],
                [[self.fs.write(root,path,text) -> "written"
local result = self.fs.write("home","PATH","TEXT")
return result]],
            },
            adapter = [[
self.fs={
 read=function(root,path) return invoke("fs","read",root,path) end,
 write=function(root,path,text) return invoke("fs","write",root,path,text) end,
}
]],
            call = function(action, arguments)
                local root = assert(roots[arguments[1]], "unknown root")
                local path = relative(arguments[2])
                if action == "read" then
                    assert(#arguments == 2, "invalid read")
                    local data = root.handle:read(path)
                    assert(utf8.len(data), "file is not UTF-8")
                    return data
                end
                assert(action == "write" and #arguments == 3, "invalid write")
                assert(type(arguments[3]) == "string" and utf8.len(arguments[3]), "invalid text")
                root.handle:write(path, arguments[3])
                return "written"
            end,
        },
        http = {
            usage = {
                [[self.http.call(action,body,headers) -> {status,body}
local response = self.http.call("model_health","",{})
return response]],
            },
            adapter = [[
self.http={call=function(action,body,headers) return invoke("http","call",action,body,headers or {}) end}
]],
            call = function(action, arguments)
                assert(action == "call" and #arguments == 3, "invalid HTTP call")
                local selected = assert(actions[arguments[1]], "unknown HTTP action")
                assert(type(arguments[2]) == "string", "invalid HTTP body")
                local status, body =
                    pa.http(selected.origin, selected.method, selected.path, arguments[2], arguments[3])
                assert(utf8.len(body), "HTTP body is not UTF-8")
                return { status = status, body = body }
            end,
        },
        search = {
            usage = {
                [[self.search.text(root,directory,query) -> string
local matches = self.search.text("home","DIRECTORY","QUERY")
return matches]],
                [[self.search.files(root,directory) -> string
local files = self.search.files("home","DIRECTORY")
return files]],
            },
            adapter = [[
self.search={
 text=function(root,directory,query) return invoke("search","text",root,directory,query) end,
 files=function(root,directory) return invoke("search","files",root,directory) end,
}
]],
            call = function(action, arguments)
                local root = assert(roots[arguments[1]], "unknown root")
                local directory = relative(arguments[2])
                local command = { "--no-follow" }
                if directory ~= "" then
                    local path = (root.path .. "/" .. directory):gsub("[*?%[%]{}\\]", "\\%0"):gsub("^/", "")
                    command[#command + 1] = "--glob"
                    command[#command + 1] = "**/" .. path .. "/**"
                end
                if action == "text" then
                    assert(#arguments == 3 and type(arguments[3]) == "string", "invalid search")
                    command[#command + 1] = "--"
                    command[#command + 1] = arguments[3]
                else
                    assert(action == "files" and #arguments == 2, "invalid search")
                    command[#command + 1] = "--files"
                    command[#command + 1] = "--"
                end
                command[#command + 1] = root.path
                local code, stdout, stderr = pa.process("/usr/bin/rg", command, "")
                assert((code == 0 or action == "text" and code == 1) and utf8.len(stdout), stderr)
                return stdout
            end,
        },
    },
}
```
