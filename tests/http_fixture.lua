local json = require("dkjson")
local uv = require("luv")

local port_file = assert(arg[1], "port file is required")
local server = assert(uv.new_tcp())
assert(server:bind("127.0.0.1", 0))
local address = assert(server:getsockname())
local file = assert(io.open(port_file, "wb"))
assert(file:write(tostring(address.port)))
assert(file:close())

local function response(client, status, content_type, body)
    client:write(
        table.concat({
            "HTTP/1.1 " .. status,
            "content-type: " .. content_type,
            "content-length: " .. #body,
            "connection: close",
            "",
            body,
        }, "\r\n"),
        function()
            client:shutdown(function()
                client:close()
            end)
        end
    )
end

assert(server:listen(32, function(problem)
    assert(not problem, problem)
    local client = assert(uv.new_tcp())
    assert(server:accept(client))
    local source = ""
    client:read_start(function(failure, chunk)
        assert(not failure, failure)
        if not chunk then
            return
        end
        source = source .. chunk
        local headers = source:find("\r\n\r\n", 1, true)
        if not headers then
            return
        end
        local length = tonumber(source:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
        if #source < headers + 3 + length then
            return
        end
        client:read_stop()
        local path = assert(source:match("^[A-Z]+%s+([^%s]+)"))
        if path == "/chat" then
            local events = {
                { choices = { { delta = { reasoning_content = "think" } } } },
                { choices = { { delta = { content = "answer" }, finish_reason = "stop" } } },
            }
            local body = "data: "
                .. assert(json.encode(events[1]))
                .. "\n\ndata: "
                .. assert(json.encode(events[2]))
                .. "\n\ndata: [DONE]\n\n"
            response(client, "200 OK", "text/event-stream", body)
        elseif path == "/rerank" then
            local request = assert(json.decode(source:sub(headers + 4)))
            local results = {}
            for index = #request.documents - 1, 0, -1 do
                results[#results + 1] = { index = index, relevance_score = index + 0.5 }
            end
            response(client, "200 OK", "application/json", assert(json.encode({ results = results })))
        elseif path == "/failure" then
            response(client, "503 Service Unavailable", "application/json", '{"error":{"message":"offline"}}')
        else
            response(client, "200 OK", "application/json", "not-json")
        end
    end)
end))

uv.run()
