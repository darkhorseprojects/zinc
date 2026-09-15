local json = require("lunajson")

local function load_preset(name)
    local file = assert(io.open("package/presets/" .. name .. ".md", "rb"))
    local source = assert(file:read("a"):match("```lua\n(.-)\n```"))
    file:close()
    local calls, document = {}, { Preset = { name } }
    local pa = {
        document = function()
            return document
        end,
    }
    function pa.fs(root)
        calls.root = root
        return {
            read = function(path)
                calls.read = path
                return "contents"
            end,
            write = function(path, data)
                calls.write = { path, data }
            end,
        }
    end
    function pa.http(origin, method, path, body, headers)
        calls.http = { origin, method, path, body, headers }
        return 200, "response"
    end
    function pa.process(executable, arguments, input)
        calls.process = { executable, arguments, input }
        return 0, "stdout", "stderr"
    end
    local environment = setmetatable({
        require = function(module)
            if module == "pa" then
                return pa
            end
            if module == "src.json" then
                return assert(loadfile("package/src/json.lua"))()
            end
            error("module not found: " .. module)
        end,
    }, { __index = _G })
    return assert(load(source, "package/presets/" .. name .. ".md", "t", environment))(), calls, document
end

describe("preset tables", function()
    it("publishes no no-host members", function()
        local preset, _, document = load_preset("no-host")
        assert.equals(document, preset.document)
        assert.same({}, preset.members)
    end)

    it("provides trusted safe defaults", function()
        local preset, calls = load_preset("safe")
        assert.same(
            { "fs", "http", "process" },
            (function()
                local names = {}
                for name in pairs(preset.members) do
                    names[#names + 1] = name
                end
                table.sort(names)
                return names
            end)()
        )
        assert.equals("string", type(preset.members.fs.prompt))
        assert.equals(
            "contents",
            json.decode(preset.members.fs.call(json.encode({ operation = "read", path = "README.md" }))).data
        )
        assert.equals("workspace", calls.root)
        preset.members.http.call(json.encode({ method = "GET", path = "/health", body = "", headers = {} }))
        assert.same({ "http://127.0.0.1:8000", "GET", "/health", "", {} }, calls.http)
        preset.members.process.call(json.encode({ query = "event", paths = { "src", "tests" } }))
        assert.same({ "/usr/bin/rg", { "--", "event", "src", "tests" }, "" }, calls.process)
    end)

    it("keeps unsafe adapters unrestricted", function()
        local preset, calls = load_preset("unsafe")
        preset.members.fs.call(json.encode({ root = "/tmp", operation = "read", path = "x" }))
        assert.equals("/tmp", calls.root)
        preset.members.http.call(
            json.encode({ origin = "https://example.com", method = "PATCH", path = "/", body = "x", headers = {} })
        )
        assert.same({ "https://example.com", "PATCH", "/", "x", {} }, calls.http)
        preset.members.process.call(json.encode({ executable = "/bin/echo", arguments = { "x" }, input = "" }))
        assert.same({ "/bin/echo", { "x" }, "" }, calls.process)
    end)
end)
