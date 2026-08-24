local uv = require("luv")
local Host = require("src.host")

local roots = {}
local function remove(path)
    local stat = uv.fs_lstat(path)
    if not stat then
        return
    end
    if stat.type == "directory" then
        local scan = assert(uv.fs_scandir(path))
        while true do
            local name = uv.fs_scandir_next(scan)
            if not name then
                break
            end
            remove(path .. "/" .. name)
        end
        assert(uv.fs_rmdir(path))
    else
        assert(uv.fs_unlink(path))
    end
end
local function root()
    local path = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/zinc-host-XXXXXX"))
    roots[#roots + 1] = path
    return path
end
local function write(path, value)
    local file = assert(io.open(path, "wb"))
    assert(file:write(value))
    assert(file:close())
end

after_each(function()
    for _, path in ipairs(roots) do
        remove(path)
    end
    roots = {}
end)

describe("Host", function()
    it("confines reads and atomic writes to configured roots", function()
        local directory, outside = root(), root()
        write(directory .. "/value.txt", "one\r\ntwo\nthree")
        write(outside .. "/secret.txt", "secret")
        assert(uv.fs_symlink(outside .. "/secret.txt", directory .. "/escape"))
        local files = Host.new({
            Files = { { root = directory, access = "read-write" } },
        }).files
        assert.equals("two\nthree", files.read({ path = directory .. "/value.txt", offset = 2, limit = 2 }))
        files.edit({ path = directory .. "/value.txt", edits = { { oldText = "two", newText = "changed" } } })
        assert.equals("one\r\nchanged\nthree", files.read({ path = directory .. "/value.txt" }))
        files.write({ path = directory .. "/new.txt", content = "new" })
        assert.equals("new", files.read({ path = directory .. "/new.txt" }))
        assert.has_error(function()
            files.read({ path = directory .. "/escape" })
        end)
        assert.has_error(function()
            files.write({ path = outside .. "/new.txt", content = "bad" })
        end)
    end)

    it("treats filesystem root as containing descendants", function()
        if package.config:sub(1, 1) == "\\" then
            return
        end
        local directory = root()
        write(directory .. "/value.txt", "rooted")
        local files = Host.new({ Files = { { root = "/", access = "read" } } }).files
        assert.equals("rooted", files.read({ path = directory .. "/value.txt" }))
    end)

    it("executes configured argument vectors without a shell", function()
        if package.config:sub(1, 1) == "\\" then
            return
        end
        local directory = root()
        local host = Host.new({
            Commands = {
                {
                    name = "print",
                    program = "/usr/bin/printf",
                    arguments = '["%s","{{value}}"]',
                    directory = directory,
                },
            },
        })
        local result = host.run({ name = "print", values = { value = "$(touch should-not-exist)" } })
        assert.equals(0, result.status)
        assert.equals("$(touch should-not-exist)", result.stdout)
        assert.falsy(uv.fs_stat(directory .. "/should-not-exist"))
    end)
end)
