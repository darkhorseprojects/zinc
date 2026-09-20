# Operations

Roots, HTTP targets, and executables are arguments.

```lua
local pa = require("pa")

local function prompt(parent, memory)
    parent = parent and tostring(parent) or "nil"
    return string.format(
        [[self({preset=P,question=Q,parent=%s,memory=%d}) -> {branch,id,parent,memory,text}
P = nil | "unsafe" | "safe" | "no-host"
self.destroy(branch) -> "destroyed"
local child = self({question="QUESTION",parent=%s,memory=%d})
self.destroy(child.branch)
return child.text]],
        parent,
        memory,
        parent,
        memory
    )
end

return {
    document = pa.document(),
    targets = { "unsafe", "safe", "no-host" },
    prompt = prompt,
    whitelist = {},
    members = {
        fs = {
            usage = {
                [[self.fs.read(root,path) -> string
local text = self.fs.read("/srv/data","notes.txt")
return text]],
                [[self.fs.write(root,path,text) -> "written"
local result = self.fs.write("/srv/data","notes.txt","TEXT")
return result]],
            },
            adapter = [[
self.fs={
 read=function(root,path) return invoke("fs","read",root,path) end,
 write=function(root,path,text) return invoke("fs","write",root,path,text) end,
}
]],
            call = function(action, arguments)
                assert(type(arguments[1]) == "string" and type(arguments[2]) == "string", "invalid filesystem call")
                local root = pa.fs(arguments[1])
                if action == "read" then
                    assert(#arguments == 2, "invalid read")
                    local data = root:read(arguments[2])
                    assert(utf8.len(data), "file is not UTF-8")
                    return data
                end
                assert(action == "write" and #arguments == 3, "invalid write")
                assert(type(arguments[3]) == "string" and utf8.len(arguments[3]), "invalid text")
                root:write(arguments[2], arguments[3])
                return "written"
            end,
        },
        http = {
            usage = {
                [[self.http.request(method,origin,path,body,headers) -> {status,body}
local response = self.http.request("GET","https://example.com","/","",{})
return response]],
            },
            adapter = [[
self.http={request=function(method,origin,path,body,headers)
 return invoke("http","request",method,origin,path,body,headers or {})
end}
]],
            call = function(action, arguments)
                assert(action == "request" and #arguments == 5, "invalid HTTP call")
                for index = 1, 4 do
                    assert(type(arguments[index]) == "string", "invalid HTTP call")
                end
                local status, body = pa.http(arguments[2], arguments[1], arguments[3], arguments[4], arguments[5])
                assert(utf8.len(body), "HTTP body is not UTF-8")
                return { status = status, body = body }
            end,
        },
        process = {
            usage = {
                [[self.process.run(executable,arguments,input) -> {code,stdout,stderr}
local result = self.process.run("/usr/bin/rg",{"--files"},"")
return result]],
            },
            adapter = [[
self.process={run=function(executable,arguments,input)
 return invoke("process","run",executable,arguments,input or "")
end}
]],
            call = function(action, arguments)
                assert(action == "run" and #arguments == 3, "invalid process call")
                assert(type(arguments[1]) == "string" and type(arguments[2]) == "table", "invalid process call")
                assert(type(arguments[3]) == "string", "invalid process input")
                for _, argument in ipairs(arguments[2]) do
                    assert(type(argument) == "string", "invalid process arguments")
                end
                local code, stdout, stderr = pa.process(arguments[1], arguments[2], arguments[3])
                assert(utf8.len(stdout) and utf8.len(stderr), "process output is not UTF-8")
                return { code = code, stdout = stdout, stderr = stderr }
            end,
        },
    },
}
```
