local uv = require("luv")
local curl = require("cURL.safe")

return function(config, source)
    local document = assert(source.Environment, "Environment document is invalid")
    local maximum = config.store_bytes
    local separator = package.config:sub(1, 1)
    local windows, cwd = separator == "\\", assert(uv.cwd())
    local function comparable(path) return windows and path:lower():gsub("\\", "/") or path end
    local function absolute(path) return path:match(windows and "^%a:[/\\]" or "^/") end

    local roots = {}
    for _, row in ipairs(document.Files or {}) do
        assert(row.access == "read" or row.access == "read-write", "file access must be read or read-write")
        local path = row.root
        if not absolute(path) then path = cwd .. separator .. path end
        local actual = assert(uv.fs_realpath(path), "file root does not exist")
        roots[#roots + 1] = {actual = actual, compare = comparable(actual), write = row.access == "read-write"}
    end

    local function checked(path, writing)
        assert(type(path) == "string" and path ~= "", "path must be nonempty text")
        if not absolute(path) then path = cwd .. separator .. path end
        local actual = uv.fs_realpath(path)
        if not actual and writing then
            local parent, name = path:match("^(.*)[/\\]([^/\\]+)$")
            actual = assert(uv.fs_realpath(parent), "path parent does not exist") .. separator .. name
        end
        actual = assert(actual, "path does not exist")
        local compare = comparable(actual)
        for _, root in ipairs(roots) do
            local inside = compare == root.compare or compare:sub(1, #root.compare + 1) == root.compare .. "/"
            if inside and (not writing or root.write) then return actual end
        end
        error("path is outside configured file roots")
    end

    local files = {}
    function files.read(path)
        local file = assert(io.open(checked(path, false), "rb"))
        local value = file:read(maximum + 1)
        assert(file:close())
        assert(#value <= maximum, "file response exceeds store_bytes")
        return value
    end

    function files.write(path, value)
        assert(type(value) == "string" and #value <= maximum, "file request exceeds store_bytes")
        local target = checked(path, true)
        local parent = assert(target:match("^(.*)[/\\][^/\\]+$"))
        local fd, temporary = assert(uv.fs_mkstemp(parent .. separator .. ".zinc-XXXXXX"))
        local ok, failure = pcall(function()
            assert(uv.fs_write(fd, value, 0) == #value, "file write failed")
            assert(uv.fs_fsync(fd)); assert(uv.fs_close(fd)); fd = nil
            assert(uv.fs_rename(temporary, target))
        end)
        if fd then uv.fs_close(fd) end
        if not ok then uv.fs_unlink(temporary); error(failure) end
    end

    function files.list(path)
        local scan = assert(uv.fs_scandir(checked(path, false)))
        local result, size = {}, 0
        while true do
            local name = uv.fs_scandir_next(scan)
            if not name then break end
            size = size + #name + 1
            assert(size <= maximum, "file response exceeds store_bytes")
            result[#result + 1] = name
        end
        table.sort(result)
        return result
    end

    local function origin(url)
        assert(type(url) == "string", "URL must be text")
        return assert(url:match("^([%a][%w+.-]*://[^/%?#]+)"), "URL has no origin"):lower()
    end
    local origins = {}
    for _, row in ipairs(document.HTTP or {}) do origins[origin(row.origin)] = true end

    local function http(options)
        assert(type(options) == "table", "HTTP options must be a table")
        assert(origins[origin(options.url)], "HTTP origin is not configured")
        assert(options.body == nil or type(options.body) == "string", "HTTP body must be text")
        assert(options.method == nil or type(options.method) == "string", "HTTP method must be text")
        assert(options.headers == nil or type(options.headers) == "table", "HTTP headers must be a table")
        local headers, requestSize = {}, #options.url + #(options.method or "GET") + #(options.body or "")
        for name, value in pairs(options.headers or {}) do
            local header = tostring(name) .. ": " .. tostring(value)
            headers[#headers + 1], requestSize = header, requestSize + #header
        end
        assert(requestSize <= maximum, "HTTP request exceeds store_bytes")
        local body, responseHeaders, size = {}, {}, 0
        local function bounded(accept)
            return function(chunk)
                size = size + #chunk
                if size > maximum then return 0 end
                accept(chunk); return #chunk
            end
        end
        local handle = assert(curl.easy({
            url = options.url, customrequest = options.method or "GET", postfields = options.body,
            httpheader = headers, followlocation = false,
            writefunction = bounded(function(chunk) body[#body + 1] = chunk end),
            headerfunction = bounded(function(line)
                local name, value = line:match("^([^:]+):%s*(.-)\r?\n$")
                if name then responseHeaders[name:lower()] = value end
            end),
        }))
        local ok, failure = handle:perform()
        local status = handle:getinfo_response_code(); handle:close()
        assert(size <= maximum, "HTTP response exceeds store_bytes")
        assert(ok, failure)
        return {status = status, headers = responseHeaders, body = table.concat(body)}
    end

    local headers = {}
    for _, row in ipairs(document.Shell or {}) do
        assert(type(row.header) == "string" and row.header ~= "", "shell header must be nonempty text")
        headers[row.header] = true
    end
    local executable = windows and assert(os.getenv("COMSPEC"), "COMSPEC is unavailable") or "/bin/sh"
    local prefix = windows and {"/d", "/s", "/c"} or {"-c"}

    local function shell(header, command)
        assert(headers[header], "shell header is not configured")
        assert(type(command) == "string" and #command <= maximum, "shell request exceeds store_bytes")
        local pipes = {stdout = uv.new_pipe(false), stderr = uv.new_pipe(false)}
        local output, ended = {stdout = {}, stderr = {}}, {stdout = false, stderr = false}
        local exited, status, signal, failure, size, handle = false, nil, nil, nil, 0
        local function read(name)
            pipes[name]:read_start(function(problem, chunk)
                if problem then failure = problem end
                if chunk then
                    size = size + #chunk
                    if size > maximum then failure = "shell output exceeds store_bytes"; handle:kill("sigterm")
                    else output[name][#output[name] + 1] = chunk end
                else ended[name] = true; pipes[name]:close() end
            end)
        end
        local arguments = {table.unpack(prefix)}; arguments[#arguments + 1] = command
        local problem
        handle, problem = uv.spawn(executable, {args = arguments, cwd = cwd, stdio = {nil, pipes.stdout, pipes.stderr}}, function(code, received) status, signal, exited = code, received, true end)
        if not handle then pipes.stdout:close(); pipes.stderr:close(); error(problem) end
        read("stdout"); read("stderr")
        while not exited or not ended.stdout or not ended.stderr do uv.run("once") end
        handle:close()
        if failure then error(failure) end
        return {status = status, signal = signal, stdout = table.concat(output.stdout), stderr = table.concat(output.stderr)}
    end

    return {guide = document.Guide, files = files, http = next(origins) and http or nil, shell = next(headers) and shell or nil}
end
