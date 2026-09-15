local sqlite = require("lsqlite3complete")

local SELECT = "SELECT id,parent,actor,memory,role,text FROM events"
local SEARCH = [[SELECT e.id,e.parent,e.actor,e.memory,e.role,e.text
FROM event_fts JOIN events e ON e.id=event_fts.rowid
WHERE event_fts MATCH ? AND e.actor=? AND e.id<=?
ORDER BY bm25(event_fts),e.id LIMIT ?]]

local function query(db, sql, ...)
    local statement = assert(db:prepare(sql), db:errmsg())
    local result = table.pack(pcall(function(...)
        assert(statement:bind_values(...) == sqlite.OK, db:errmsg())
        local rows = {}
        for row in statement:nrows() do
            rows[#rows + 1] = row
        end
        return rows
    end, ...))
    local finalized = statement:finalize()
    if not result[1] then
        error(result[2], 0)
    end
    assert(finalized == sqlite.OK, db:errmsg())
    return result[2]
end

local function tail(value, maximum)
    if #value <= maximum then
        return value
    end
    return (value:sub(-maximum):gsub("^[\128-\191]*", ""))
end

return function(config)
    assert(type(config.path) == "string" and config.path ~= "", "invalid Store path")
    local db = assert(sqlite.open(config.path))
    db:busy_timeout(5000)
    local initialized, problem = pcall(function()
        assert(
            db:exec("PRAGMA trusted_schema=OFF; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON") == sqlite.OK,
            db:errmsg()
        )
        local version = query(db, "PRAGMA user_version")[1].user_version
        assert(version == 0 or version == 4, "Store format is unsupported")
        if version == 0 then
            assert(db:exec([[
PRAGMA journal_mode=WAL;
CREATE TABLE events(
 id INTEGER PRIMARY KEY,
 parent INTEGER REFERENCES events(id),
 actor TEXT NOT NULL,
 memory INTEGER NOT NULL,
 role TEXT NOT NULL CHECK(role IN ('user','assistant','tool')),
 text TEXT NOT NULL CHECK(length(text)>0)
) STRICT;
CREATE INDEX events_by_actor ON events(actor,id);
CREATE VIRTUAL TABLE event_fts USING fts5(
 text,content='events',content_rowid='id',tokenize='unicode61 remove_diacritics 0'
);
CREATE TRIGGER events_fts_insert AFTER INSERT ON events BEGIN
 INSERT INTO event_fts(rowid,text) VALUES(new.id,new.text);
END;
CREATE TRIGGER events_parent_actor BEFORE INSERT ON events
WHEN new.parent IS NOT NULL AND NOT EXISTS(
 SELECT 1 FROM events WHERE id=new.parent AND actor=new.actor
) BEGIN SELECT raise(ABORT,'invalid parent'); END;
CREATE TRIGGER events_memory_actor BEFORE INSERT ON events
WHEN new.memory<0 OR (new.memory<>0 AND NOT EXISTS(
 SELECT 1 FROM events WHERE id=new.memory AND actor=new.actor
)) BEGIN SELECT raise(ABORT,'invalid memory'); END;
PRAGMA user_version=4;
]]) == sqlite.OK, db:errmsg())
        end
    end)
    if not initialized then
        db:close()
        error(problem, 0)
    end

    local store = {}
    function store:validate(actor, parent, memory)
        assert(type(actor) == "string" and actor ~= "", "invalid actor")
        assert(parent == nil or math.type(parent) == "integer" and parent > 0, "invalid parent")
        assert(math.type(memory) == "integer" and memory >= 0, "invalid memory")
        if parent then
            assert(query(db, SELECT .. " WHERE actor=? AND id=?", actor, parent)[1], "parent is unavailable")
        end
        if memory ~= 0 then
            assert(query(db, SELECT .. " WHERE actor=? AND id=?", actor, memory)[1], "memory is unavailable")
        end
    end

    function store:append(actor, parent, memory, events, maximum)
        assert(type(events) == "table" and #events > 0, "events must be nonempty")
        assert(db:exec("BEGIN IMMEDIATE") == sqlite.OK, db:errmsg())
        local result = table.pack(pcall(function()
            local rows = {}
            for index, event in ipairs(events) do
                assert(type(event) == "table" and type(event.text) == "string", "invalid event")
                assert(event.text ~= "" and utf8.len(event.text), "invalid event text")
                local row = query(
                    db,
                    [[INSERT INTO events(parent,actor,memory,role,text) VALUES(?,?,?,?,?)
RETURNING id,parent,actor,memory,role,text]],
                    parent,
                    actor,
                    memory,
                    event.role,
                    tail(event.text, maximum)
                )[1]
                rows[index], parent = row, row.id
            end
            assert(db:exec("COMMIT") == sqlite.OK, db:errmsg())
            return rows
        end))
        if result[1] then
            return result[2]
        end
        db:exec("ROLLBACK")
        error(result[2], 0)
    end

    function store:before(actor, memory, limit)
        if memory == 0 then
            return {}
        end
        return query(db, SELECT .. " WHERE actor=? AND id<=? ORDER BY id DESC LIMIT ?", actor, memory, limit)
    end

    function store:search(actor, memory, terms, limit)
        if #terms == 0 or memory == 0 then
            return {}
        end
        local literals = {}
        for index, term in ipairs(terms) do
            literals[index] = '"' .. term:gsub('"', '""') .. '"'
        end
        return query(db, SEARCH, table.concat(literals, " OR "), actor, memory, limit)
    end

    function store:close()
        assert(db:close() == sqlite.OK, "failed to close Store")
    end

    return store
end
