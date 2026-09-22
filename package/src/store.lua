local sqlite = require("lsqlite3complete")

local SCHEMA = [[
PRAGMA journal_mode=WAL;
CREATE TABLE runs(
 id INTEGER PRIMARY KEY,
 actor TEXT NOT NULL,
 budget INTEGER NOT NULL CHECK(budget>0),
 used INTEGER NOT NULL DEFAULT 0 CHECK(used>=0)
) STRICT;
CREATE TABLE branches(
 id INTEGER PRIMARY KEY,
 run INTEGER NOT NULL REFERENCES runs(id),
 base INTEGER REFERENCES events(id) ON DELETE CASCADE,
 memory INTEGER REFERENCES events(id) ON DELETE CASCADE,
 preset TEXT NOT NULL,
 temporary INTEGER NOT NULL CHECK(temporary IN (0,1))
) STRICT;
CREATE TABLE events(
 id INTEGER PRIMARY KEY,
 branch INTEGER NOT NULL REFERENCES branches(id) ON DELETE CASCADE,
 kind TEXT NOT NULL CHECK(kind IN ('user','reasoning','response','call','result')),
 tokens INTEGER,
 text TEXT NOT NULL CHECK(length(text)>0),
 CHECK((kind IN ('call','result'))=(tokens IS NOT NULL))
) STRICT;
CREATE INDEX branches_by_run ON branches(run,id);
CREATE INDEX events_by_branch ON events(branch,id);
CREATE VIRTUAL TABLE event_fts USING fts5(
 text,content='events',content_rowid='id',tokenize='unicode61 remove_diacritics 0'
);
CREATE TRIGGER event_fts_insert AFTER INSERT ON events BEGIN
 INSERT INTO event_fts(rowid,text) VALUES(new.id,new.text);
END;
CREATE TRIGGER event_fts_delete AFTER DELETE ON events BEGIN
 INSERT INTO event_fts(event_fts,rowid,text) VALUES('delete',old.id,old.text);
END;
CREATE TRIGGER branch_coordinates BEFORE INSERT ON branches
WHEN EXISTS(
 SELECT 1 FROM runs current
 WHERE current.id=new.run AND (
  new.base IS NOT NULL AND NOT EXISTS(
   SELECT 1 FROM events e JOIN branches b ON b.id=e.branch JOIN runs r ON r.id=b.run
   WHERE e.id=new.base AND r.actor=current.actor AND (new.temporary=1 OR b.temporary=0)
  ) OR
  new.memory IS NOT NULL AND NOT EXISTS(
   SELECT 1 FROM events e JOIN branches b ON b.id=e.branch JOIN runs r ON r.id=b.run
   WHERE e.id=new.memory AND r.actor=current.actor AND (new.temporary=1 OR b.temporary=0)
  )
 )
)
BEGIN SELECT raise(ABORT,'invalid branch coordinates'); END;
PRAGMA user_version=5;
]]

local BEFORE = [[WITH RECURSIVE visible(id) AS (
 SELECT ? UNION
 SELECT parent.branch FROM visible v JOIN branches child ON child.id=v.id
 JOIN events parent ON parent.id=child.base
)
SELECT e.id,b.id branch,
 COALESCE((SELECT max(previous.id) FROM events previous WHERE previous.branch=e.branch AND previous.id<e.id),b.base) parent,
 b.memory,e.kind,e.text
FROM events e JOIN branches b ON b.id=e.branch JOIN runs r ON r.id=b.run
WHERE r.actor=? AND e.id<=? AND (b.temporary=0 OR b.id IN visible)
ORDER BY e.id DESC LIMIT ?]]

local SEARCH = [[WITH RECURSIVE visible(id) AS (
 SELECT ? UNION
 SELECT parent.branch FROM visible v JOIN branches child ON child.id=v.id
 JOIN events parent ON parent.id=child.base
)
SELECT e.id,b.id branch,
 COALESCE((SELECT max(previous.id) FROM events previous WHERE previous.branch=e.branch AND previous.id<e.id),b.base) parent,
 b.memory,e.kind,e.text
FROM event_fts JOIN events e ON e.id=event_fts.rowid
JOIN branches b ON b.id=e.branch JOIN runs r ON r.id=b.run
WHERE event_fts MATCH ? AND r.actor=? AND e.id<=? AND (b.temporary=0 OR b.id IN visible)
ORDER BY bm25(event_fts),e.id LIMIT ?]]

local function prepare(db, source)
    return assert(db:prepare(source), db:errmsg())
end

local function rows(db, statement, ...)
    local reset = statement:reset()
    assert(reset == sqlite.OK or reset == sqlite.DONE, db:errmsg())
    assert(statement:bind_values(...) == sqlite.OK, db:errmsg())
    local output = {}
    for row in statement:nrows() do
        output[#output + 1] = row
    end
    return output
end

return function(config)
    local db = assert(sqlite.open(config.path))
    db:busy_timeout(5000)
    local opened, statements = pcall(function()
        assert(
            db:exec("PRAGMA trusted_schema=OFF; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON") == sqlite.OK,
            db:errmsg()
        )
        local version_statement = prepare(db, "PRAGMA user_version")
        local version = rows(db, version_statement)[1].user_version
        assert(version_statement:finalize() == sqlite.OK, db:errmsg())
        assert(version == 0 or version == 5, "Store format is unsupported")
        if version == 0 then
            assert(db:exec(SCHEMA) == sqlite.OK, db:errmsg())
        end
        return {
            start_run = prepare(db, "INSERT INTO runs(actor,budget) VALUES(?,?) RETURNING id"),
            branch = prepare(
                db,
                "INSERT INTO branches(run,base,memory,preset,temporary) VALUES(?,?,?,?,?) RETURNING id,run,base,memory,preset,temporary"
            ),
            branch_info = prepare(db, "SELECT id,run,base,memory,preset,temporary FROM branches WHERE id=?"),
            caller = prepare(
                db,
                [[SELECT r.id run,r.actor,r.budget,b.id branch,b.preset
FROM events e JOIN branches b ON b.id=e.branch JOIN runs r ON r.id=b.run
WHERE e.id=? AND e.kind='call' AND r.actor=?]]
            ),
            insert = prepare(db, "INSERT INTO events(branch,kind,tokens,text) VALUES(?,?,?,?) RETURNING id"),
            charge = prepare(db, "UPDATE runs SET used=used+? WHERE id=?"),
            last = prepare(db, "SELECT id FROM events WHERE branch=? ORDER BY id DESC LIMIT 1"),
            head = prepare(
                db,
                [[SELECT e.id FROM events e
JOIN branches b ON b.id=e.branch JOIN runs r ON r.id=b.run
WHERE r.actor=? AND b.temporary=0 AND e.kind='response'
ORDER BY e.id DESC LIMIT 1]]
            ),
            quota = prepare(db, "SELECT budget-used remaining FROM runs WHERE id=?"),
            destroy = prepare(
                db,
                [[WITH RECURSIVE ancestors(id) AS (
 SELECT ? UNION
 SELECT parent.branch FROM ancestors a JOIN branches child ON child.id=a.id
 JOIN events parent ON parent.id=child.base
)
DELETE FROM branches WHERE id=? AND temporary=1 AND id NOT IN ancestors
AND run IN (SELECT id FROM runs WHERE actor=?) RETURNING id]]
            ),
            before = prepare(db, BEFORE),
            search = prepare(db, SEARCH),
        }
    end)
    if not opened then
        db:close()
        error(statements, 0)
    end

    local function transaction(body)
        assert(db:exec("BEGIN IMMEDIATE") == sqlite.OK, db:errmsg())
        local result = table.pack(pcall(body))
        if result[1] then
            assert(db:exec("COMMIT") == sqlite.OK, db:errmsg())
            return table.unpack(result, 2, result.n)
        end
        db:exec("ROLLBACK")
        error(result[2], 0)
    end

    local function append(branch, events)
        local info = assert(rows(db, statements.branch_info, branch)[1], "branch is unavailable")
        local previous = rows(db, statements.last, branch)[1]
        local parent = previous and previous.id or info.base
        local output = {}
        for index, event in ipairs(events) do
            assert(type(event.text) == "string" and event.text ~= "" and utf8.len(event.text), "invalid event text")
            local metered = event.kind == "call" or event.kind == "result"
            assert(metered == (math.type(event.tokens) == "integer" and event.tokens >= 0), "invalid event tokens")
            local id = rows(db, statements.insert, branch, event.kind, event.tokens, event.text)[1].id
            if event.tokens then
                local reset = statements.charge:reset()
                assert(reset == sqlite.OK or reset == sqlite.DONE, db:errmsg())
                assert(statements.charge:bind_values(event.tokens, info.run) == sqlite.OK, db:errmsg())
                assert(statements.charge:step() == sqlite.DONE, db:errmsg())
            end
            output[index] = {
                id = id,
                branch = branch,
                parent = parent,
                memory = info.memory or 0,
                kind = event.kind,
                tokens = event.tokens,
                text = event.text,
            }
            parent = id
        end
        return output
    end

    local store = {}

    function store:start(actor, budget, base, memory, preset, question)
        return transaction(function()
            local run = rows(db, statements.start_run, actor, budget)[1].id
            local branch = rows(db, statements.branch, run, base, memory ~= 0 and memory or nil, preset, 0)[1]
            return run, branch.id, append(branch.id, { { kind = "user", text = question } })[1]
        end)
    end

    function store:child(run, base, memory, preset, question)
        return transaction(function()
            local branch = rows(db, statements.branch, run, base, memory ~= 0 and memory or nil, preset, 1)[1]
            return branch.id, append(branch.id, { { kind = "user", text = question } })[1]
        end)
    end

    function store:append(branch, events)
        return transaction(function()
            return append(branch, events)
        end)
    end

    function store:admit(branch, calls)
        return transaction(function()
            local info = assert(rows(db, statements.branch_info, branch)[1], "branch is unavailable")
            local remaining = rows(db, statements.quota, info.run)[1].remaining
            local admitted = {}
            for index, call in ipairs(calls) do
                if call.tokens <= remaining then
                    admitted[index] = { accepted = true, row = append(branch, { call })[1] }
                    remaining = remaining - call.tokens
                else
                    admitted[index] = { accepted = false }
                end
            end
            return admitted
        end)
    end

    function store:caller(actor, event)
        return assert(rows(db, statements.caller, event, actor)[1], "caller is unavailable")
    end

    function store:head(actor)
        local row = rows(db, statements.head, actor)[1]
        return row and row.id or nil
    end

    function store:quota(run)
        return assert(rows(db, statements.quota, run)[1], "run is unavailable").remaining
    end

    function store:destroy(actor, caller_branch, branch)
        return transaction(function()
            assert(rows(db, statements.destroy, caller_branch, branch, actor)[1], "branch is unavailable")
        end)
    end

    function store:before(actor, memory, branch, limit)
        if memory == 0 then
            return {}
        end
        return rows(db, statements.before, branch, actor, memory, limit)
    end

    function store:search(actor, memory, branch, terms, limit)
        if #terms == 0 or memory == 0 then
            return {}
        end
        local literals = {}
        for index, term in ipairs(terms) do
            literals[index] = '"' .. term:gsub('"', '""') .. '"'
        end
        return rows(db, statements.search, branch, table.concat(literals, " OR "), actor, memory, limit)
    end

    function store:close()
        for _, statement in pairs(statements) do
            assert(statement:finalize() == sqlite.OK, db:errmsg())
        end
        assert(db:close() == sqlite.OK, "failed to close Store")
    end

    return store
end
