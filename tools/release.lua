local uv = require("luv")

local function execute(program, arguments)
    local output, errors = {}, {}
    local stdout, stderr = assert(uv.new_pipe(false)), assert(uv.new_pipe(false))
    local exited, status, signal = false
    local handle, problem = uv.spawn(program, {
        args = arguments,
        cwd = assert(uv.cwd()),
        stdio = { nil, stdout, stderr },
    }, function(code, received)
        status, signal, exited = code, received, true
    end)
    assert(handle, problem)
    stdout:read_start(function(failure, chunk)
        assert(not failure, failure)
        if chunk then
            output[#output + 1] = chunk
        else
            stdout:close()
        end
    end)
    stderr:read_start(function(failure, chunk)
        assert(not failure, failure)
        if chunk then
            errors[#errors + 1] = chunk
        else
            stderr:close()
        end
    end)
    while not exited or not stdout:is_closing() or not stderr:is_closing() do
        uv.run("once")
    end
    handle:close()
    assert(status == 0 and signal == 0, program .. " failed: " .. table.concat(errors))
    return table.concat(output)
end

execute("moon", { "run", "dist" })
local archive = "zinc-1.0.0-x86_64-linux-gnu.tar.gz"
os.remove("dist/" .. archive)
execute("tar", {
    "--sort=name",
    "--mtime=@0",
    "--owner=0",
    "--group=0",
    "--numeric-owner",
    "-czf",
    "dist/" .. archive,
    "-C",
    "dist",
    "zinc",
})
local checksum = execute("sha256sum", { "dist/" .. archive }):gsub("  dist/", "  ")
local file = assert(io.open("dist/SHA256SUMS", "wb"))
assert(file:write(checksum))
assert(file:close())
print("dist/" .. archive)
print("dist/SHA256SUMS")
