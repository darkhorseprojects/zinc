local sqlite = require("lsqlite3")
local json = require("dkjson")
local uv = require("luv")

local function encode(value)
    local text, failure = json.encode(value)
    if not text then error(failure) end
    return text
end

local function mkdir(path)
    if uv.fs_stat(path) then return end
    local parent = path:match("^(.*)[/\\][^/\\]+$")
    if parent and parent ~= "" and parent ~= path then mkdir(parent) end
    local ok, failure, code = uv.fs_mkdir(path, 448)
    if not ok then assert(code == "EEXIST" and uv.fs_stat(path), failure) end
end

return function(config)
    local separator = package.config:sub(1, 1)
    assert(config.store:match("^[^/\\]+$") and config.store ~= "." and config.store ~= "..", "store must be a local directory name")
    local home = assert(os.getenv(separator == "\\" and "USERPROFILE" or "HOME"), "home directory is unavailable")
    local directory = table.concat({home, ".agents", "zinc", config.store}, separator)
    mkdir(directory)
    local db = assert(sqlite.open(directory .. separator .. "zinc.sqlite3"))
    db:busy_timeout(5000)
    assert(db:load_extension(assert(package.searchpath("vec0", package.cpath))))

    local function rows(sql, ...)
        local statement = assert(db:prepare(sql), db:errmsg())
        assert(statement:bind_values(...) == sqlite.OK, db:errmsg())
        local result = {}
        for row in statement:nrows() do result[#result + 1] = row end
        statement:finalize()
        return result
    end

    local function execute(sql, ...)
        local statement = assert(db:prepare(sql), db:errmsg())
        assert(statement:bind_values(...) == sqlite.OK, db:errmsg())
        local code = statement:step()
        statement:finalize()
        assert(code == sqlite.DONE, db:errmsg())
    end

    local function transaction(work)
        assert(db:exec("BEGIN IMMEDIATE") == sqlite.OK, db:errmsg())
        local result = table.pack(pcall(work))
        if not result[1] then
            db:exec("ROLLBACK")
            error(result[2])
        end
        assert(db:exec("COMMIT") == sqlite.OK, db:errmsg())
        return table.unpack(result, 2, result.n)
    end

    local function slice(row)
        local value = json.decode(row.data)
        value.idx, value.run, value.actor = row.idx, row.run, row.actor
        return value
    end

    local function edge(run, direction)
        local row = rows("SELECT idx,run,actor,data FROM slices WHERE run=? ORDER BY idx " .. direction .. " LIMIT 1", run)[1]
        return row and slice(row)
    end

    local function status(run)
        local value = edge(run, "DESC")
        if not value then return nil end
        if value.type == "response" and value.source == "zinc" then return "complete" end
        return "incomplete"
    end

    local function insert(run, value)
        local origin = assert(edge(run, "ASC"), "Run does not exist")
        execute("INSERT INTO slices(run,actor,data) VALUES(?,?,?)", run, origin.actor, encode(value))
        return db:last_insert_rowid()
    end

    local code
    for _ = 1, 5 do
        code = db:exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
        if code == sqlite.OK or code ~= sqlite.BUSY and code ~= sqlite.LOCKED then break end
        uv.sleep(50)
    end
    assert(code == sqlite.OK, db:errmsg())
    local schema = [[
CREATE TABLE IF NOT EXISTS slices(
    idx INTEGER PRIMARY KEY AUTOINCREMENT,
    run INTEGER NOT NULL,
    actor TEXT NOT NULL,
    data TEXT NOT NULL CHECK(json_valid(data))
) STRICT;
CREATE INDEX IF NOT EXISTS slices_by_run ON slices(run,idx);
CREATE VIRTUAL TABLE IF NOT EXISTS slice_vec USING vec0(
    idx INTEGER PRIMARY KEY,
    actor TEXT PARTITION KEY,
    embedding float[1024]
);
PRAGMA application_id=1514753603;
PRAGMA user_version=4;
]]
    transaction(function()
        local application = rows("PRAGMA application_id")[1].application_id
        local version = rows("PRAGMA user_version")[1].user_version
        local occupied = rows("SELECT count(*) count FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")[1].count > 0
        if application ~= 0 and application ~= 1514753603 or application == 0 and occupied or version ~= 0 and version ~= 4 then
            error("unsupported Zinc Store")
        end
        assert(db:exec(schema) == sqlite.OK, db:errmsg())
    end)

    local complete = [[(
        json_extract((SELECT data FROM slices z WHERE z.run=s.run ORDER BY z.idx DESC LIMIT 1),'$.type')='merged'
        OR (
            json_extract((SELECT data FROM slices z WHERE z.run=s.run ORDER BY z.idx DESC LIMIT 1),'$.type')='response'
            AND json_extract((SELECT data FROM slices z WHERE z.run=s.run ORDER BY z.idx DESC LIMIT 1),'$.source')='zinc'
        )
    )]]
    local api = {}

    function api:snapshot()
        local row = rows("SELECT seq value FROM sqlite_sequence WHERE name='slices'")[1]
        return row and row.value or 0
    end

    function api:begin(spec)
        assert(type(spec.request) == "string", "request must be text")
        assert(type(spec.actor) == "string" and spec.actor ~= "", "actor must be nonempty text")
        assert(type(spec.snapshot) == "number" and spec.snapshot >= 0, "snapshot is invalid")
        return transaction(function()
            if spec.parent ~= nil then assert(status(spec.parent) == "incomplete", "parent Run is not active") end
            local data = encode({
                type = "request",
                parent = spec.parent or json.null,
                snapshot = spec.snapshot,
                value = spec.request,
                memory = spec.memory or {},
            })
            execute("INSERT INTO slices(run,actor,data) VALUES(0,?,?)", spec.actor, data)
            local run = db:last_insert_rowid()
            execute("UPDATE slices SET run=? WHERE idx=?", run, run)
            return run
        end)
    end

    function api:append(run, event)
        assert(status(run) == "incomplete", "Run is not active")
        assert(type(event) == "table" and event.type and event.source, "invalid event")
        return insert(run, event)
    end

    function api:merge(child, parent, request)
        assert(request == nil or type(request) == "string", "request must be text")
        return transaction(function()
            assert(status(parent) == "incomplete", "parent Run is not active")
            local head, tail = edge(child, "ASC"), edge(child, "DESC")
            assert(head and head.parent == parent and tail and tail.type == "response" and tail.source == "zinc", "child Run cannot be merged")
            local events = {}
            for _, row in ipairs(rows("SELECT idx,run,actor,data FROM slices WHERE run=? AND idx>? ORDER BY idx", child, head.idx)) do
                events[#events + 1] = slice(row)
            end
            local payload = {type = "merged", child = child, request = request or json.null, events = events}
            return insert(parent, payload)
        end)
    end

    function api:discard(child, parent)
        transaction(function()
            local origin = edge(child, "ASC")
            assert(origin and origin.parent == parent and status(child) ~= "merged" and status(parent) == "incomplete", "child Run cannot be discarded")
            local tree = "WITH RECURSIVE tree(run) AS (SELECT ? UNION ALL SELECT s.run FROM slices s JOIN tree t ON json_extract(s.data,'$.parent')=t.run WHERE json_extract(s.data,'$.type')='request') "
            execute(tree .. "DELETE FROM slice_vec WHERE idx IN (SELECT idx FROM slices WHERE run IN tree)", child)
            execute(tree .. "DELETE FROM slices WHERE run IN tree", child)
        end)
    end

    function api:tail(actor, snapshot, maximum)
        local sql = "SELECT s.idx,s.run,s.actor,s.data FROM slices s WHERE s.actor=? AND s.idx<=? AND " .. complete .. " ORDER BY s.idx DESC"
        local result, size = {}, 0
        for _, row in ipairs(rows(sql, actor, snapshot)) do
            if size + #row.data > maximum then break end
            size = size + #row.data
            result[#result + 1] = slice(row)
        end
        local ordered = {}
        for index = #result, 1, -1 do ordered[#ordered + 1] = result[index] end
        return ordered, size
    end

    function api:missing(ids)
        if #ids == 0 then return {} end
        local missing = {}
        for _, row in ipairs(rows("SELECT value idx FROM json_each(?) WHERE value NOT IN (SELECT idx FROM slice_vec)", encode(ids))) do missing[#missing + 1] = row.idx end
        return missing
    end

    function api:index(values)
        transaction(function()
            for _, value in ipairs(values) do
                execute("INSERT OR REPLACE INTO slice_vec(idx,actor,embedding) VALUES(?,?,?)", value.idx, value.actor, encode(value.vector))
            end
        end)
    end

    function api:nearest(vector, actor, first, snapshot, limit)
        if limit <= 0 then return {} end
        local sql = "SELECT idx, distance FROM slice_vec WHERE actor=? AND embedding MATCH ? AND k=?"
        local results = {}
        for _, row in ipairs(rows(sql, actor, encode(vector), limit)) do
            if row.idx >= first and row.idx <= snapshot then
                results[#results + 1] = row
            end
        end
        return results
    end

    function api:fetch(ids, actor, snapshot)
        if #ids == 0 then return {} end
        local found = {}
        local sql = "SELECT s.idx,s.run,s.actor,s.data FROM slices s WHERE s.idx IN (SELECT value FROM json_each(?)) AND s.actor=? AND s.idx<=? AND " .. complete
        for _, row in ipairs(rows(sql, encode(ids), actor, snapshot)) do found[row.idx] = slice(row) end
        local result = {}
        for _, idx in ipairs(ids) do if found[idx] then result[#result + 1] = found[idx] end end
        return result
    end

    function api:slice(idx)
        local row = rows("SELECT idx,run,actor,data FROM slices WHERE idx=?", idx)[1]
        return row and slice(row) or nil
    end

    function api:run(runId)
        local sql = "SELECT s.idx,s.run,s.actor,s.data FROM slices s WHERE s.run=? ORDER BY s.idx"
        local result = {}
        for _, row in ipairs(rows(sql, runId)) do result[#result + 1] = slice(row) end
        return result
    end

    function api:visibleSlice(actor, snapshot, idx)
        return self:fetch({idx}, actor, snapshot)[1]
    end

    function api:visibleRun(actor, snapshot, run, maximum)
        local sql = "SELECT s.idx,s.run,s.actor,s.data FROM slices s WHERE s.actor=? AND s.idx<=? AND (s.run=? OR (json_extract(s.data,'$.type')='merged' AND json_extract(s.data,'$.child')=?)) AND " .. complete .. " ORDER BY s.idx"
        local result, size = {}, 0
        for _, row in ipairs(rows(sql, actor, snapshot, run, run)) do
            assert(size + #row.data <= maximum, "Run exceeds store_bytes")
            size = size + #row.data
            result[#result + 1] = slice(row)
        end
        return result
    end

    function api:close() assert(db:close() == sqlite.OK) end
    return api
end
