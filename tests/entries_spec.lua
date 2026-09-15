local function source(path)
    local file = assert(io.open(path, "rb"))
    local value = assert(file:read("a"))
    file:close()
    return value
end

local function fence(path)
    return assert(source(path):match("```lua\n(.-)\n```"))
end

describe("Zinc package composition", function()
    it("uses one entry and literal preset modules", function()
        assert.is_truthy(source("package/zinc.md"):find('require("src.entry")', 1, true))
        for _, name in ipairs({ "unsafe", "safe", "no-host" }) do
            local path = "package/presets/" .. name .. ".md"
            assert.is_truthy(source(path):find('require("pa")', 1, true))
            assert.is_truthy(source(path):find("members", 1, true))
        end
        assert.is_nil(io.open("package/host/safe.md", "rb"))
        assert.is_nil(io.open("package/src/internal/run.lua", "rb"))
    end)

    it("owns deployment configuration and composes presets", function()
        local captured, document, design = nil, {}, {}
        local presets = { unsafe = {}, safe = {}, ["no-host"] = {} }
        local environment = setmetatable({}, { __index = _G })
        environment.require = function(name)
            if name == "pa" then
                return {
                    document = function()
                        return document
                    end,
                }
            end
            if name == "design" then
                return design
            end
            if name == "presets.unsafe" then
                return presets.unsafe
            end
            if name == "presets.safe" then
                return presets.safe
            end
            if name == "presets.no-host" then
                return presets["no-host"]
            end
            if name == "src.entry" then
                return function(config)
                    captured = config
                    return "entry"
                end
            end
            error("module not found: " .. name)
        end
        assert.equals("entry", assert(load(fence("package/zinc.md"), "package/zinc.md", "t", environment))())
        assert.equals(document, captured.document)
        assert.equals(design, captured.design)
        assert.equals(presets.safe, captured.presets.safe)
        assert.equals(presets.unsafe, captured.presets.unsafe)
        assert.equals(presets["no-host"], captured.presets["no-host"])
        assert.equals("http://127.0.0.1:8000", captured.model.origin)
        assert.equals("state/zinc.db", captured.store.path)
        assert.equals(false, getmetatable(captured))
    end)
end)
