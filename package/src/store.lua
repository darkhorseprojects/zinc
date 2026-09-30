local sqlite = require("lsqlite3complete")

local SCHEMA = [[
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
 temporary INTEGER NOT NULL CHECK(temporary IN (0,1)),
 result INTEGER REFERENCES events(id)
) STRICT;
CREATE TABLE events(
 id INTEGER PRIMARY KEY,
 branch INTEGER NOT NULL REFERENCES branches(id) ON DELETE CASCADE,
 kind TEXT NOT NULL CHECK(kind IN ('user','reasoning','response','call','result')),
 text TEXT NOT NULL CHECK(length(text)>0)
) STRICT;
CREATE INDEX branches_by_run ON branches(run,id);
CREATE INDEX events_by_branch ON events(branch,id);
CREATE VIRTUAL TABLE event_fts USING fts5(
 text,content='events',content_rowid='id',tokenize='unicode61 remove_diacritics 0'
);
CREATE TRIGGER event_fts_insert AFTER INSERT ON events
WHEN new.kind IN ('user','response','result') BEGIN
 INSERT INTO event_fts(rowid,text) VALUES(new.id,new.text);
END;
CREATE TRIGGER event_fts_delete AFTER DELETE ON events
WHEN old.kind IN ('user','response','result') BEGIN
 INSERT INTO event_fts(event_fts,rowid,text) VALUES('delete',old.id,old.text);
END;
CREATE TRIGGER branch_coordinates BEFORE INSERT ON branches
WHEN EXISTS(
 SELECT 1 FROM runs current
 WHERE current.id=new.run AND (
  new.base IS NOT NULL AND NOT EXISTS(
   SELECT 1 FROM events e JOIN branches b ON b.id=e.branch JOIN runs r ON r.id=b.run
   WHERE e.id=new.base AND r.actor=current.actor AND (
    b.temporary=0 OR new.temporary=1 AND b.run=new.run
   )
  ) OR
  new.memory IS NOT NULL AND NOT EXISTS(
   SELECT 1 FROM events e JOIN branches b ON b.id=e.branch JOIN runs r ON r.id=b.run
   WHERE e.id=new.memory AND r.actor=current.actor AND (
    b.temporary=0 OR
    new.temporary=1 AND b.run=new.run AND b.id IN (
     WITH RECURSIVE lineage(id) AS (
      SELECT branch FROM events WHERE id=new.base UNION ALL
      SELECT parent.branch FROM lineage l JOIN branches child ON child.id=l.id
      JOIN events parent ON parent.id=child.base
     ) SELECT id FROM lineage
    )
   )
  )
 )
)
BEGIN SELECT raise(ABORT,'invalid branch coordinates'); END;
]]
local LEXICON = [[
CREATE TABLE lexemes(
 id INTEGER PRIMARY KEY,
 actor TEXT NOT NULL,
 term TEXT NOT NULL,
 documents INTEGER NOT NULL CHECK(documents>=0),
 UNIQUE(actor,term)
) STRICT;
CREATE TABLE event_lexemes(
 event INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
 lexeme INTEGER NOT NULL REFERENCES lexemes(id),
 PRIMARY KEY(event,lexeme)
) WITHOUT ROWID;
CREATE INDEX event_lexemes_by_lexeme ON event_lexemes(lexeme,event);
CREATE VIRTUAL TABLE lexeme_grams USING fts5(
 term,content='lexemes',content_rowid='id',tokenize='trigram',detail='none'
);
CREATE TRIGGER lexeme_grams_insert AFTER INSERT ON lexemes BEGIN
 INSERT INTO lexeme_grams(rowid,term) VALUES(new.id,new.term);
END;
CREATE TRIGGER lexeme_grams_delete AFTER DELETE ON lexemes BEGIN
 INSERT INTO lexeme_grams(lexeme_grams,rowid,term) VALUES('delete',old.id,old.term);
END;
CREATE TRIGGER event_lexemes_delete AFTER DELETE ON event_lexemes BEGIN
 UPDATE lexemes SET documents=documents-1 WHERE id=old.lexeme;
 DELETE FROM lexemes WHERE id=old.lexeme AND documents=0;
END;
]]

local VISIBLE = [[WITH RECURSIVE visible(id,ceiling) AS (
 SELECT ?,? UNION ALL
 SELECT parent.branch,min(v.ceiling,child.base) FROM visible v
 JOIN branches child ON child.id=v.id JOIN events parent ON parent.id=child.base
)
]]
local RECORD = [[SELECT e.id,b.id branch,
 COALESCE((SELECT max(previous.id) FROM events previous WHERE previous.branch=e.branch AND previous.id<e.id),b.base) parent,
 b.memory,e.kind,e.text
FROM events e JOIN branches b ON b.id=e.branch JOIN runs r ON r.id=b.run
]]
local SCOPE = [[r.actor=? AND e.id<=? AND (
 b.temporary=0 OR
 EXISTS(SELECT 1 FROM visible v WHERE v.id=b.id AND e.id<=v.ceiling)
)
]]
local BEFORE = VISIBLE .. RECORD .. "WHERE " .. SCOPE .. "ORDER BY e.id DESC LIMIT ?"
local SEARCH = VISIBLE
    .. RECORD
    .. "JOIN event_fts ON event_fts.rowid=e.id WHERE event_fts MATCH ? AND "
    .. SCOPE
    .. "AND e.kind IN ('user','response','result') ORDER BY bm25(event_fts),e.id LIMIT ?"
local FREQUENCY = VISIBLE
    .. [[SELECT count(*) hits FROM (
SELECT 1 FROM event_lexemes link JOIN events e ON e.id=link.event
JOIN branches b ON b.id=e.branch JOIN runs r ON r.id=b.run
WHERE link.lexeme=? AND ]]
    .. SCOPE
    .. "LIMIT ?)"

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
        assert(version == 0 or version == 3, "Store format is unsupported; Zinc 0.2 requires a fresh Store")
        assert(db:exec([[
CREATE VIRTUAL TABLE temp.event_tokenizer USING fts5(text,tokenize='unicode61 remove_diacritics 0');
CREATE VIRTUAL TABLE temp.event_vocabulary USING fts5vocab(event_tokenizer,'row');
]]) == sqlite.OK, db:errmsg())
        if version == 0 then
            assert(db:exec("PRAGMA journal_mode=WAL") == sqlite.OK, db:errmsg())
            assert(db:exec("BEGIN IMMEDIATE") == sqlite.OK, db:errmsg())
            local created, problem = pcall(function()
                assert(db:exec(SCHEMA .. LEXICON .. "PRAGMA user_version=3") == sqlite.OK, db:errmsg())
            end)
            if not created then
                db:exec("ROLLBACK")
                error(problem, 0)
            end
            assert(db:exec("COMMIT") == sqlite.OK, db:errmsg())
        end
        return {
            tokenize = prepare(db, "INSERT INTO temp.event_tokenizer(text) VALUES(?) RETURNING rowid"),
            lexeme_insert = prepare(
                db,
                [[INSERT INTO lexemes(actor,term,documents)
SELECT ?,term,1 FROM temp.event_vocabulary WHERE length(term)<=128
ON CONFLICT(actor,term) DO UPDATE SET documents=documents+1]]
            ),
            lexeme_link = prepare(
                db,
                [[INSERT INTO event_lexemes(event,lexeme)
SELECT ?,l.id FROM temp.event_vocabulary v JOIN lexemes l ON l.actor=? AND l.term=v.term
WHERE length(v.term)<=128]]
            ),
            lexeme_exact = prepare(db, "SELECT id,term FROM lexemes WHERE actor=? AND term=?"),
            lexeme_near = prepare(db, VISIBLE .. [[SELECT l.id,l.term FROM lexeme_grams
JOIN lexemes l ON l.id=lexeme_grams.rowid WHERE lexeme_grams MATCH ? AND l.actor=?
AND EXISTS(SELECT 1 FROM event_lexemes link JOIN events e ON e.id=link.event
JOIN branches b ON b.id=e.branch JOIN runs r ON r.id=b.run
WHERE link.lexeme=l.id AND ]] .. SCOPE .. [[)
ORDER BY bm25(lexeme_grams),l.id LIMIT ?]]),
            start_run = prepare(db, "INSERT INTO runs(actor,budget) VALUES(?,?) RETURNING id"),
            branch = prepare(
                db,
                "INSERT INTO branches(run,base,memory,preset,temporary) VALUES(?,?,?,?,?) RETURNING id,run,base,memory,preset,temporary"
            ),
            branch_info = prepare(
                db,
                [[SELECT b.id,b.run,b.base,b.memory,b.preset,b.temporary,b.result,r.actor
FROM branches b JOIN runs r ON r.id=b.run WHERE b.id=?]]
            ),
            finish = prepare(
                db,
                [[UPDATE branches SET result=? WHERE id=? AND temporary=0 AND result IS NULL
AND EXISTS(SELECT 1 FROM events WHERE id=? AND branch=? AND kind='response') RETURNING id]]
            ),
            caller = prepare(
                db,
                [[SELECT r.id run,r.actor,r.budget,b.id branch,b.preset
FROM events e JOIN branches b ON b.id=e.branch JOIN runs r ON r.id=b.run
WHERE e.id=? AND e.kind='call' AND r.actor=?]]
            ),
            insert = prepare(db, "INSERT INTO events(branch,kind,text) VALUES(?,?,?) RETURNING id"),
            charge = prepare(db, "UPDATE runs SET used=used+? WHERE id=? RETURNING id"),
            last = prepare(db, "SELECT id FROM events WHERE branch=? ORDER BY id DESC LIMIT 1"),
            head = prepare(
                db,
                [[SELECT e.id FROM events e
JOIN branches b ON b.id=e.branch JOIN runs r ON r.id=b.run
WHERE r.actor=? AND b.temporary=0
ORDER BY e.id DESC LIMIT 1]]
            ),
            quota = prepare(db, "SELECT budget-used remaining,used FROM runs WHERE id=?"),
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
            frequency = prepare(db, FREQUENCY),
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
            local id = rows(db, statements.insert, branch, event.kind, event.text)[1].id
            if event.kind == "user" or event.kind == "response" or event.kind == "result" then
                assert(db:exec("DELETE FROM temp.event_tokenizer") == sqlite.OK, db:errmsg())
                assert(rows(db, statements.tokenize, event.text)[1], "failed to tokenize event")
                rows(db, statements.lexeme_insert, info.actor)
                rows(db, statements.lexeme_link, id, info.actor)
            end
            output[index] = {
                id = id,
                branch = branch,
                parent = parent,
                memory = info.memory or 0,
                kind = event.kind,
                text = event.text,
            }
            parent = id
        end
        return output
    end

    local store = {}

    function store:start(actor, budget, base, memory, preset, question, automatic)
        return transaction(function()
            if automatic then
                local head = rows(db, statements.head, actor)[1]
                base = head and head.id or nil
            end
            if memory == nil then
                memory = base or 0
            end
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

    function store:finish(branch, result)
        return transaction(function()
            assert(rows(db, statements.finish, result, branch, result, branch)[1], "invalid terminal response")
        end)
    end

    function store:append(branch, events)
        return transaction(function()
            return append(branch, events)
        end)
    end

    function store:charge(run, tokens)
        assert(math.type(tokens) == "integer" and tokens >= 0, "invalid model usage")
        return transaction(function()
            assert(rows(db, statements.charge, tokens, run)[1], "run is unavailable")
        end)
    end

    function store:caller(actor, event)
        return assert(rows(db, statements.caller, event, actor)[1], "caller is unavailable")
    end

    function store:quota(run)
        local row = assert(rows(db, statements.quota, run)[1], "run is unavailable")
        return row.remaining, row.used
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
        return rows(db, statements.before, branch, memory, actor, memory, limit)
    end

    function store:lexemes(actor, memory, branch, term, grams, limit)
        local found = rows(db, statements.lexeme_exact, actor, term)
        if grams ~= "" and memory ~= 0 then
            for _, row in ipairs(rows(db, statements.lexeme_near, branch, memory, grams, actor, actor, memory, limit)) do
                if row.term ~= term then
                    found[#found + 1] = row
                end
            end
        end
        return found
    end

    function store:frequency(actor, memory, branch, lexeme)
        if memory == 0 then
            return 0
        end
        return rows(db, statements.frequency, branch, memory, lexeme, actor, memory, 32)[1].hits
    end

    function store:search(actor, memory, branch, terms, limit)
        if #terms == 0 or memory == 0 then
            return {}
        end
        local literals = {}
        for index, term in ipairs(terms) do
            literals[index] = '"' .. term:gsub('"', '""') .. '"'
        end
        return rows(db, statements.search, branch, memory, table.concat(literals, " OR "), actor, memory, limit)
    end

    function store:close()
        for _, statement in pairs(statements) do
            assert(statement:finalize() == sqlite.OK, db:errmsg())
        end
        assert(db:close() == sqlite.OK, "failed to close Store")
    end

    return store
end
