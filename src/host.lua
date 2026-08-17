local uv = require("luv")
local curl = require("cURL.safe")
local json = require("dkjson")

local separator = package.config:sub(1, 1)
local windows = separator == "\\"

local function decode(source, what)
    local value, position, failure = json.decode(source, 1, json.null)
    assert(not failure and not source:sub(position):find("%S"), failure or what .. " has trailing data")
    return value
end

local function comparable(path)
    path = path:gsub("\\", "/")
    return windows and path:lower() or path
end

local function absolute(path)
    return windows and (path:match("^%a:[/\\]") or path:match("^[/\\][/\\]")) or path:match("^/")
end

local function files(rows, cwd, home)
    local roots = {}
    local function expand(path)
        assert(type(path) == "string" and path ~= "", "path must be nonempty text")
        if path == "~" then
            return home
        elseif path:sub(1, 2) == "~/" or path:sub(1, 2) == "~\\" then
            return home .. separator .. path:sub(3)
        end
        return absolute(path) and path or cwd .. separator .. path
    end
    for _, row in ipairs(rows or {}) do
        assert(row.access == "read" or row.access == "read-write", "file access must be read or read-write")
        local actual = assert(uv.fs_realpath(expand(row.root)), "file root does not exist: " .. tostring(row.root))
        roots[#roots + 1] = { path = comparable(actual), write = row.access == "read-write" }
    end

    local function checked(path, writing)
        local expanded, actual = expand(path)
        actual = uv.fs_realpath(expanded)
        if not actual and writing then
            local parent, name = expanded:match("^(.*)[/\\]([^/\\]+)$")
            assert(parent and name and name ~= "." and name ~= "..", "invalid output path")
            actual = assert(uv.fs_realpath(parent), "parent directory does not exist: " .. path) .. separator .. name
        end
        assert(actual, "path does not exist: " .. path)
        local candidate = comparable(actual)
        for _, root in ipairs(roots) do
            if candidate == root.path or candidate:sub(1, #root.path + 1) == root.path .. "/" then
                assert(not writing or root.write, "path is not inside a writable root: " .. path)
                return actual
            end
        end
        error("path is outside configured roots: " .. path)
    end

    local function read(path)
        local file = assert(io.open(path, "rb"))
        local value = assert(file:read("*a"))
        assert(file:close())
        assert(utf8.len(value), "file is not valid UTF-8")
        return value
    end

    local function publish(target, value, mode)
        assert(type(value) == "string", "file content must be text")
        local parent = assert(target:match("^(.*)[/\\][^/\\]+$"), "invalid output path")
        local fd, temporary = assert(uv.fs_mkstemp(parent .. separator .. ".zinc-XXXXXX"))
        local open = true
        local ok, failure = pcall(function()
            assert(uv.fs_write(fd, value, 0) == #value, "file write failed")
            if mode then
                assert(uv.fs_fchmod(fd, mode))
            end
            assert(uv.fs_fsync(fd))
            assert(uv.fs_close(fd))
            open = false
            assert(uv.fs_rename(temporary, target))
        end)
        if open then
            uv.fs_close(fd)
        end
        if not ok then
            uv.fs_unlink(temporary)
            error(failure, 0)
        end
    end

    return {
        read = function(request)
            assert(type(request) == "table", "read request must be a table")
            local value = read(checked(request.path, false))
            if request.offset == nil and request.limit == nil then
                return value
            end
            local offset = request.offset == nil and 1
                or assert(math.tointeger(request.offset), "offset must be an integer")
            local limit = request.limit == nil and math.huge
                or assert(math.tointeger(request.limit), "limit must be an integer")
            assert(offset > 0 and limit > 0, "offset and limit must be positive")
            local selected, index = {}, 0
            for line in (value .. "\n"):gmatch("(.-)\n") do
                index = index + 1
                if index >= offset and index < offset + limit then
                    selected[#selected + 1] = line:gsub("\r$", "")
                end
            end
            return table.concat(selected, "\n")
        end,
        edit = function(request)
            assert(type(request) == "table" and type(request.edits) == "table", "edit request is invalid")
            local target = checked(request.path, true)
            local original, ranges = read(target), {}
            for index, edit in ipairs(request.edits) do
                assert(type(edit.oldText) == "string" and edit.oldText ~= "", "oldText must be nonempty text")
                assert(type(edit.newText) == "string", "newText must be text")
                local first = assert(original:find(edit.oldText, 1, true), "oldText was not found")
                assert(not original:find(edit.oldText, first + 1, true), "oldText is not unique")
                ranges[index] = { first, first + #edit.oldText - 1, edit.newText }
            end
            table.sort(ranges, function(left, right)
                return left[1] < right[1]
            end)
            local parts, cursor = {}, 1
            for index, range in ipairs(ranges) do
                assert(index == 1 or range[1] > ranges[index - 1][2], "edits overlap")
                parts[#parts + 1], parts[#parts + 2], cursor =
                    original:sub(cursor, range[1] - 1), range[3], range[2] + 1
            end
            parts[#parts + 1] = original:sub(cursor)
            assert(read(target) == original, "file changed since it was read")
            local mode = not windows and assert(uv.fs_stat(target)).mode % 512 or nil
            publish(target, table.concat(parts), mode)
        end,
        write = function(request)
            assert(type(request) == "table" and type(request.content) == "string", "write request is invalid")
            publish(checked(request.path, true), request.content)
        end,
    }
end

local function http(rows)
    local function origin(url)
        assert(type(url) == "string", "URL must be text")
        return assert(url:match("^([%a][%w+.-]*://[^/%?#]+)"), "URL has no origin"):lower()
    end
    local origins = {}
    for _, row in ipairs(rows or {}) do
        origins[origin(row.origin)] = true
    end
    if not next(origins) then
        return nil
    end
    local forbidden = { host = true, ["content-length"] = true, ["transfer-encoding"] = true, connection = true }
    return function(request)
        assert(type(request) == "table" and origins[origin(request.url)], "HTTP origin is not configured")
        assert(request.body == nil or type(request.body) == "string", "HTTP body must be text")
        assert(request.method == nil or type(request.method) == "string", "HTTP method must be text")
        assert(request.headers == nil or type(request.headers) == "table", "HTTP headers must be a table")
        local headers = {}
        for raw_name, raw_value in pairs(request.headers or {}) do
            local name, value = tostring(raw_name), tostring(raw_value)
            assert(not name:find("[\r\n]") and not value:find("[\r\n]"), "HTTP headers cannot contain line breaks")
            assert(not forbidden[name:lower()], "HTTP header is managed by the client: " .. name)
            headers[#headers + 1] = name .. ": " .. value
        end
        local body, response_headers = {}, {}
        local handle = assert(curl.easy({
            url = request.url,
            customrequest = request.method or "GET",
            postfields = request.body,
            httpheader = headers,
            followlocation = false,
            writefunction = function(chunk)
                body[#body + 1] = chunk
                return #chunk
            end,
            headerfunction = function(line)
                local name, value = line:match("^([^:]+):%s*(.-)\r?\n$")
                if name then
                    response_headers[name:lower()] = value
                end
                return #line
            end,
        }))
        local ok, failure = handle:perform()
        local status = handle:getinfo_response_code()
        handle:close()
        assert(ok, failure)
        return { status = status, headers = response_headers, body = table.concat(body) }
    end
end

local function processes(rows, variables, cwd)
    local commands = {}
    for _, row in ipairs(rows or {}) do
        assert(type(row.name) == "string" and row.name ~= "" and not commands[row.name], "command name is invalid")
        local arguments = decode(row.arguments or "[]", "command arguments")
        assert(type(arguments) == "table", "command arguments must be a JSON array")
        commands[row.name] = { program = row.program, arguments = arguments, directory = row.directory or "." }
    end
    if not next(commands) then
        return nil
    end
    local inherited, environment = uv.os_environ(), {}
    for _, row in ipairs(variables or {}) do
        assert(type(row.name) == "string" and row.name:match("^[%a_][%w_]*$"), "variable name is invalid")
        if inherited[row.name] ~= nil then
            environment[#environment + 1] = row.name .. "=" .. inherited[row.name]
        end
    end

    local function arguments(shape, values)
        local result, used = {}, {}
        for _, token in ipairs(shape) do
            local name, many = token:match("^{{([%a_][%w_]*)}}$"), false
            if not name then
                name = token:match("^{{([%a_][%w_]*)%.%.%.}}$")
                many = name ~= nil
            end
            if not name then
                result[#result + 1] = token
            else
                local value = values[name]
                assert(value ~= nil, "missing command value: " .. name)
                used[name] = true
                if many then
                    assert(type(value) == "table", "command array value must be an array: " .. name)
                    for _, item in ipairs(value) do
                        assert(
                            type(item) == "string" and not item:find("%z"),
                            "command arguments must be text without NUL"
                        )
                        result[#result + 1] = item
                    end
                else
                    assert(type(value) == "string" and not value:find("%z"), "command value must be text without NUL")
                    result[#result + 1] = value
                end
            end
        end
        for name in pairs(values) do
            assert(used[name], "unknown command value: " .. tostring(name))
        end
        return result
    end

    return function(request)
        assert(type(request) == "table", "process request must be a table")
        local command = assert(commands[request.name], "command is not configured: " .. tostring(request.name))
        local input = request.input or ""
        assert(type(input) == "string", "process input must be text")
        local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
        local chunks, ended = { stdout = {}, stderr = {} }, { stdout = false, stderr = false }
        local exited, status, signal, failure, handle = false
        local function read(name, pipe)
            pipe:read_start(function(problem, chunk)
                failure = failure or problem
                if chunk then
                    chunks[name][#chunks[name] + 1] = chunk
                else
                    ended[name] = true
                    pipe:close()
                end
            end)
        end
        local problem
        handle, problem = uv.spawn(assert(command.program, "command program is required"), {
            args = arguments(command.arguments, request.values or {}),
            cwd = absolute(command.directory) and command.directory or cwd .. separator .. command.directory,
            env = environment,
            stdio = { stdin, stdout, stderr },
        }, function(code, received)
            status, signal, exited = code, received, true
        end)
        assert(handle, problem)
        read("stdout", stdout)
        read("stderr", stderr)
        stdin:write(input, function(problem)
            failure = failure or problem
            stdin:shutdown(function()
                stdin:close()
            end)
        end)
        while not exited or not ended.stdout or not ended.stderr do
            uv.run("once")
        end
        handle:close()
        assert(not failure, failure)
        return {
            status = status,
            signal = signal,
            stdout = table.concat(chunks.stdout),
            stderr = table.concat(chunks.stderr),
        }
    end
end

local module = {}

function module.new(document)
    assert(type(document) == "table", "Host document is invalid")
    local cwd, home = assert(uv.cwd()), assert(uv.os_homedir())
    return {
        guide = document.Guide,
        files = files(document.Files, cwd, home),
        http = http(document.HTTP),
        run = processes(document.Commands, document.Variables, cwd),
    }
end

return module
