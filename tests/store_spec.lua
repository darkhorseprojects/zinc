local sqlite = require("lsqlite3complete")
local make_store = assert(loadfile("package/src/store.lua"))()

local function path()
    local value = os.tmpname()
    os.remove(value)
    return value
end

local function remove(value)
    os.remove(value)
    os.remove(value .. "-shm")
    os.remove(value .. "-wal")
end

local function add(store, actor, parent, memory, role, text)
    return store:append(actor, parent, memory, { { role = role, text = text } }, 4096)[1]
end

describe("event Store", function()
    it("creates ordered branches with independent coordinates", function()
        local file = path()
        local store = make_store({ path = file })
        local root = add(store, "actor", nil, 0, "user", "root")
        local rows = store:append("actor", root.id, root.id, {
            { role = "assistant", text = "first" },
            { role = "tool", text = "second" },
        }, 4096)
        local sibling = add(store, "actor", root.id, rows[2].id, "user", "sibling")
        assert.equals(root.id, rows[1].parent)
        assert.equals(rows[1].id, rows[2].parent)
        assert.equals(root.id, sibling.parent)
        assert.equals(rows[2].id, sibling.memory)
        store:close()
        remove(file)
    end)

    it("atomically rejects foreign coordinates", function()
        local file = path()
        local store = make_store({ path = file })
        local event = add(store, "one", nil, 0, "user", "private")
        assert.has_error(function()
            add(store, "two", event.id, 0, "user", "bad")
        end, "invalid parent")
        assert.has_error(function()
            add(store, "two", nil, event.id, "user", "bad")
        end, "invalid memory")
        assert.has_error(function()
            store:validate("two", event.id, 0)
        end, "parent is unavailable")
        store:close()
        remove(file)
    end)

    it("rejects obsolete versions and releases the database", function()
        local file = path()
        local db = assert(sqlite.open(file))
        assert(db:exec("PRAGMA user_version=3") == sqlite.OK)
        assert(db:close() == sqlite.OK)
        assert.has_error(function()
            make_store({ path = file })
        end, "Store format is unsupported")
        assert(os.remove(file))
    end)
end)
