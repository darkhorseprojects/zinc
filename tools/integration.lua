local json = require("dkjson")
local uv = require("luv")

local function execute(program, arguments, options)
    options = options or {}
    local stdout, stderr = assert(uv.new_pipe(false)), assert(uv.new_pipe(false))
    local stdin = options.input and assert(uv.new_pipe(false)) or nil
    local output, errors, ended = {}, {}, { stdout = false, stderr = false }
    local exited, status, signal = false
    local handle, problem = uv.spawn(program, {
        args = arguments,
        cwd = options.cwd,
        env = options.env,
        stdio = { stdin, stdout, stderr },
    }, function(code, received)
        status, signal, exited = code, received, true
    end)
    assert(handle, problem)
    local function read(name, pipe, chunks)
        pipe:read_start(function(failure, chunk)
            assert(not failure, failure)
            if chunk then
                chunks[#chunks + 1] = chunk
            else
                ended[name] = true
                pipe:close()
            end
        end)
    end
    read("stdout", stdout, output)
    read("stderr", stderr, errors)
    if stdin then
        stdin:write(options.input, function(failure)
            assert(not failure, failure)
            stdin:shutdown(function()
                stdin:close()
            end)
        end)
    end
    while not exited or not ended.stdout or not ended.stderr do
        uv.run("once")
    end
    handle:close()
    local error_text = table.concat(errors)
    assert(status == 0 and signal == 0, program .. " failed: " .. error_text)
    return table.concat(output), error_text
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local value = assert(file:read("*a"))
    assert(file:close())
    return value
end

local function write(path, value)
    local file = assert(io.open(path, "wb"))
    assert(file:write(value))
    assert(file:close())
end

local configured_agent = assert(os.getenv("AGENT_BIN"), "AGENT_BIN is required")
local agent = assert(uv.fs_realpath(configured_agent), "AGENT_BIN is invalid")
assert(uv.fs_stat("dist/zinc/zinc.md"), "run moon run dist before integration")
local root = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/zinc-integration-XXXXXX"))
local server, server_exited
local ok, failure = xpcall(function()
    local port_file = root .. "/port"
    server_exited = false
    server = assert(uv.spawn(assert(uv.exepath()), {
        args = { "tests/http_fixture.lua", port_file },
        cwd = assert(uv.cwd()),
        stdio = { nil, nil, nil },
    }, function()
        server_exited = true
    end))
    local port
    for _ = 1, 200 do
        local file = io.open(port_file, "rb")
        if file then
            port = assert(tonumber(assert(file:read("*a"))))
            assert(file:close())
            break
        end
        uv.sleep(5)
    end
    assert(port, "HTTP fixture did not start")
    execute("/usr/bin/cp", { "-a", "--reflink=auto", "dist/zinc", root .. "/package" })
    local entry_path = root .. "/package/zinc.md"
    local entry = read(entry_path)
        :gsub("http://127.0.0.1:8000/v1/chat/completions", "http://127.0.0.1:" .. port .. "/chat")
        :gsub("http://127.0.0.1:8001/rerank", "http://127.0.0.1:" .. port .. "/rerank")
    write(entry_path, entry)
    local output = execute(agent, {
        "run",
        "--directory",
        ".",
        "--entry",
        "zinc.md",
        "--mount",
        "host=host.md",
        "--mount",
        "design=design.md",
        "--trust",
        "src.cygnet",
        "--trust",
        "src.dependencies",
        "--trust",
        "src.host",
        "--trust",
        "src.models",
        "--trust",
        "src.store",
        "--lua-memory",
        "96MiB",
        "--",
        "integration-actor",
    }, {
        cwd = root .. "/package",
        input = "hello",
        env = {
            "HOME=" .. root .. "/home",
            "PATH=/usr/bin:/bin",
            "LUA_PATH=/missing/?.lua",
            "LUA_CPATH=/missing/?.so",
        },
    })
    local events = {}
    for line in output:gmatch("[^\n]+") do
        events[#events + 1] = assert(json.decode(line))
    end
    assert(events[2].type == "response" and events[2].text == "answer", "chat response was not streamed")
    local terminal = events[#events]
    assert(terminal.type == "store" and terminal.result == 3 and terminal.start == 1, "terminal Store event is invalid")
    assert(uv.fs_stat(root .. "/package/store/zinc.db"), "package-local Store was not created")
    assert(not uv.fs_stat(root .. "/package/store/zinc.db-wal"), "WAL remained after execution")
    assert(not uv.fs_stat(root .. "/package/store/zinc.db-shm"), "SHM remained after execution")
end, debug.traceback)
if server and not server_exited then
    server:kill("sigterm")
end
while server and not server_exited do
    uv.run("once")
end
if server then
    server:close()
end
execute("/usr/bin/rm", { "-rf", root })
assert(ok, failure)
print("installed-package integration passed")
