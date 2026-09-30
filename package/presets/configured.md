# Operations

Filesystem paths and search directories are relative to their named roots. `.` searches the whole root; `./` is optional before a file path. HTTP calls take a string body and a headers table.

```lua
local pa = require("pa")

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

return {
    document = pa.document(),
    targets = { "configured", "none" },
    members = {
        fs = {
            usage = {
                "self.fs.read(root,path) -> string (UTF-8 file text)",
                [[self.fs.write(root,path,text) -> "written"]],
            },
            adapter = [[
self.fs={
 read=function(root,path) return invoke("fs","read",root,path) end,
 write=function(root,path,text) return invoke("fs","write",root,path,text) end,
}
]],
            call = function(action, arguments, tools)
                local root <close> = pa.fs(assert(tools.roots[arguments[1]], "unknown root"))
                local path = relative(arguments[2])
                if action == "read" then
                    assert(#arguments == 2, "invalid read")
                    local data = root:read(path)
                    assert(utf8.len(data), "file is not UTF-8")
                    return data
                end
                assert(action == "write" and #arguments == 3, "invalid write")
                assert(type(arguments[3]) == "string" and utf8.len(arguments[3]), "invalid text")
                root:write(path, arguments[3])
                return "written"
            end,
        },
        http = {
            usage = { "self.http.call(action,body,headers) -> {status,body}" },
            adapter = [[
self.http={call=function(action,body,headers) return invoke("http","call",action,body,headers or {}) end}
]],
            call = function(action, arguments, tools)
                assert(action == "call" and #arguments == 3, "invalid HTTP call")
                local selected = assert(tools.actions[arguments[1]], "unknown HTTP action")
                assert(type(arguments[2]) == "string", "invalid HTTP body")
                local status, body =
                    pa.http(selected.origin, selected.method, selected.path, arguments[2], arguments[3])
                assert(utf8.len(body), "HTTP body is not UTF-8")
                return { status = status, body = body }
            end,
        },
        search = {
            usage = {
                "self.search.text(root,directory,query) -> string (matching lines)",
                "self.search.files(root,directory) -> string (file paths)",
            },
            adapter = [[
self.search={
 text=function(root,directory,query) return invoke("search","text",root,directory,query) end,
 files=function(root,directory) return invoke("search","files",root,directory) end,
}
]],
            call = function(action, arguments, tools)
                local root = assert(tools.roots[arguments[1]], "unknown root")
                local directory = relative(arguments[2])
                local command = { "--no-follow" }
                if directory ~= "" then
                    local path = (root .. "/" .. directory):gsub("[*?%[%]{}\\]", "\\%0"):gsub("^/", "")
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
                command[#command + 1] = root
                local code, stdout, stderr =
                    pa.process(assert(tools.search, "search executable is not configured"), command, "")
                assert((code == 0 or action == "text" and code == 1) and utf8.len(stdout), stderr)
                return stdout
            end,
        },
    },
}
```
