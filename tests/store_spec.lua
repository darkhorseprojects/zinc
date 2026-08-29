local sqlite = require("lsqlite3complete")
local Store = require("src.store")

local paths = {}
local function temporary()
    local path = os.tmpname()
    os.remove(path)
    paths[#paths + 1], paths[#paths + 2], paths[#paths + 3] = path, path .. "-wal", path .. "-shm"
    local directory, name = assert(path:match("^(.*)[/\\]([^/\\]+)$"))
    return directory, name, path
end
local function open(maximum)
    local directory, name, path = temporary()
    return Store({ store = name, max_stored_record_bytes = maximum }, directory), path, directory, name
end

after_each(function()
    for _, path in ipairs(paths) do
        os.remove(path)
    end
    paths = {}
end)

describe("Store", function()
    it("creates package-local durable state with actor isolation", function()
        local store, path = open(5)
        local first = store:begin("actor", "old 😀 request")
        local assistant = store:append("actor", first.id, "assistant", "assistant 😀")
        local tool = store:append("actor", first.id, "tool", "tool 😀")
        local current = store:begin("actor", "current")
        local other = store:begin("other", "hidden")

        assert.equals(first.id, first.start)
        assert.equals(current.id, current.start)
        assert.equals(first.id, assistant.start)
        assert.equals("tool", tool.role)
        assert.is_true(#first.text <= 5)
        assert.is_truthy(utf8.len(first.text))
        assert.equals(assistant.id, store:read("actor", current.id, assistant.id).id)
        assert.is_nil(store:read("other", other.id, assistant.id))
        assert.is_nil(store:read("actor", first.id, assistant.id))

        local before = {}
        store:before("actor", current.id, function(record)
            before[#before + 1] = record.id
        end)
        assert.same({ tool.id, assistant.id, first.id }, before)
        local around = store:around("actor", current.id, assistant.id)
        assert.equals(first.id, around.previous.id)
        assert.equals(tool.id, around.next.id)
        store:close()

        local file = assert(io.open(path, "rb"))
        file:close()
        local db = assert(sqlite.open(path))
        local version
        for row in db:nrows("PRAGMA user_version") do
            version = row.user_version
        end
        assert.equals(2, version)
        local columns = {}
        for row in db:nrows("PRAGMA table_info(results)") do
            columns[#columns + 1] = row.name
        end
        assert.same({ "id", "actor_id", "start", "role", "text" }, columns)
        assert.equals(sqlite.OK, db:close())
    end)

    it("uses SQLite tokenization and rejects excess semantic work", function()
        local store = open(1000)
        assert.same({
            terms = { "Hello", "sqlite3_open_v2", "sqlite3", "open", "v2" },
            tokens = { "hello", "sqlite3", "open", "v2", "hello" },
            exact_forms = { "sqlite3_open_v2" },
        }, store:ground("Hello sqlite3_open_v2 hello", 10, 100, 100))
        assert.same({
            terms = { "one", "two" },
            tokens = { "one", "two", "three" },
            exact_forms = {},
        }, store:ground("one two three", 2, 100, 100))
        assert.has_error(function()
            store:ground("one two three", 10, 2, 10)
        end, "grounding text exceeds semantic input token limit")
        assert.has_error(function()
            store:ground("one_two three_four", 10, 10, 1)
        end, "grounding text exceeds exact form limit")
        store:close()
    end)

    it("indexes actor identity and text in one bounded FTS query", function()
        local store = open(1000)
        local alpha = store:begin("actor", "common alpha").id
        local beta = store:begin("actor", "common beta").id
        local rare = store:begin("actor", "rare delta").id
        store:begin("other", "rare hidden")
        local current = store:begin("actor", "now")
        local found = store:search("actor", current.id, { "common", "rare", "absent" }, 100)
        local ids = {}
        for _, record in ipairs(found) do
            ids[record.id] = true
        end
        assert.same({ [alpha] = true, [beta] = true, [rare] = true }, ids)
        local hidden = store:search("other", current.id, { "rare" }, 100)
        assert.equals(1, #hidden)
        assert.equals("other", hidden[1].actor)
        store:close()
    end)

    it("serializes independent writers without crossing actors", function()
        local first, path, directory, name = open(1000)
        local second = Store({ store = name, max_stored_record_bytes = 1000 }, directory)
        for index = 1, 25 do
            local a = first:begin("actor-a", "request " .. index)
            first:append("actor-a", a.id, "assistant", "response " .. index)
            local b = second:begin("actor-b", "request " .. index)
            second:append("actor-b", b.id, "assistant", "response " .. index)
        end
        first:close()
        second:close()
        local db = assert(sqlite.open(path))
        local actors, records = 0, 0
        for row in db:nrows("SELECT count(*) AS count FROM actors") do
            actors = row.count
        end
        for row in db:nrows("SELECT count(*) AS count FROM results") do
            records = row.count
        end
        assert.equals(2, actors)
        assert.equals(100, records)
        assert.equals(sqlite.OK, db:close())
    end)

    it("rejects paths outside the package", function()
        local directory = temporary()
        for _, path in ipairs({ "/tmp/zinc.db", "store/../zinc.db", "store\\zinc.db", "" }) do
            assert.has_error(function()
                Store({ store = path, max_stored_record_bytes = 1000 }, directory)
            end)
        end
    end)
end)
