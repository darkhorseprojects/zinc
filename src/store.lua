local sqlite = require("lsqlite3complete")
local APPLICATION_ID, SCHEMA_VERSION = 1514753603, 2
local PRAGMAS = "PRAGMA trusted_schema=OFF; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL"
local INSERT = "INSERT INTO results(id,actor_id,start,role,text) VALUES(?,?,?,?,?)"
local SEARCH = [[
SELECT r.id,a.actor,r.start,r.role,r.text,bm25(result_fts,0.0,1.0) lexical_score
FROM result_fts JOIN results r ON r.id=result_fts.rowid JOIN actors a ON a.id=r.actor_id
WHERE result_fts MATCH ? AND r.actor_id=? AND r.id<? ORDER BY lexical_score,r.id LIMIT ?
]]

local function tail(value, maximum)
    if #value <= maximum then
        return value
    end
    local first = #value - maximum + 1
    while value:byte(first) >= 128 and value:byte(first) < 192 do
        first = first + 1
    end
    return value:sub(first)
end

return function(config, directory)
    assert(type(config.store) == "string" and config.store:match("^[%w_.-]+$"), "invalid Store path")
    local maximum = assert(math.tointeger(config.max_stored_record_bytes), "stored record budget must be an integer")
    assert(maximum >= 4, "stored record budget must be at least four bytes")
    local db = assert(sqlite.open(directory .. package.config:sub(1, 1) .. config.store))
    db:busy_timeout(5000)

    local function rows(sql, ...)
        local statement = assert(db:prepare(sql), db:errmsg())
        assert(statement:bind_values(...) == sqlite.OK, db:errmsg())
        local result = {}
        for row in statement:nrows() do
            result[#result + 1] = row
        end
        assert(statement:finalize() == sqlite.OK, db:errmsg())
        return result
    end

    local function execute(sql, ...)
        local statement = assert(db:prepare(sql), db:errmsg())
        assert(statement:bind_values(...) == sqlite.OK, db:errmsg())
        assert(statement:step() == sqlite.DONE, db:errmsg())
        assert(statement:finalize() == sqlite.OK, db:errmsg())
    end
    local result_select = "SELECT r.id,a.actor,r.start,r.role,r.text FROM results r JOIN actors a ON a.id=r.actor_id"
    local function one(where, ...)
        return rows(result_select .. where, ...)[1]
    end

    local function transaction(work)
        assert(db:exec("BEGIN IMMEDIATE") == sqlite.OK, db:errmsg())
        local result = table.pack(pcall(work))
        if result[1] and db:exec("COMMIT") == sqlite.OK then
            return table.unpack(result, 2, result.n)
        end
        local failure = result[1] and db:errmsg() or result[2]
        db:exec("ROLLBACK")
        error(failure, 0)
    end

    assert(db:exec(PRAGMAS) == sqlite.OK, db:errmsg())
    local identity = rows("PRAGMA application_id")[1].application_id
    local version = rows("PRAGMA user_version")[1].user_version
    local existing = rows("SELECT name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' LIMIT 1")
    if identity == 0 then
        assert(version == 0 and #existing == 0, "Store database is not empty")
    else
        assert(identity == APPLICATION_ID and version == SCHEMA_VERSION, "Store format is unsupported")
    end
    assert(db:exec(string.format(
        [[
CREATE TABLE IF NOT EXISTS actors(id INTEGER PRIMARY KEY,actor TEXT NOT NULL UNIQUE) STRICT;
CREATE TABLE IF NOT EXISTS results(
 id INTEGER PRIMARY KEY,actor_id INTEGER NOT NULL REFERENCES actors(id),start INTEGER NOT NULL,
 role TEXT NOT NULL CHECK(role IN ('user','assistant','tool')),text TEXT NOT NULL CHECK(length(text)>0),
 UNIQUE(id,actor_id),FOREIGN KEY(start,actor_id) REFERENCES results(id,actor_id)
) STRICT;
CREATE INDEX IF NOT EXISTS results_by_actor_id ON results(actor_id,id);
CREATE VIRTUAL TABLE IF NOT EXISTS result_fts USING fts5(
 actor_id,text,content='results',content_rowid='id',tokenize='unicode61 remove_diacritics 0'
);
CREATE TRIGGER IF NOT EXISTS results_fts_insert AFTER INSERT ON results BEGIN
 INSERT INTO result_fts(rowid,actor_id,text) VALUES(new.id,new.actor_id,new.text);
END;
PRAGMA application_id=%d; PRAGMA user_version=%d;
]],
        APPLICATION_ID,
        SCHEMA_VERSION
    )) == sqlite.OK, db:errmsg())
    assert(db:exec([[
CREATE VIRTUAL TABLE temp.grounding_tokenizer USING fts5(text,tokenize='unicode61 remove_diacritics 0');
CREATE VIRTUAL TABLE temp.grounding_vocabulary USING fts5vocab(grounding_tokenizer,'instance');
]]) == sqlite.OK, db:errmsg())

    local function actor_id(actor, create)
        assert(type(actor) == "string" and actor ~= "" and utf8.len(actor), "actor must be valid nonempty text")
        if create then
            execute("INSERT OR IGNORE INTO actors(actor) VALUES(?)", actor)
        end
        local row = rows("SELECT id FROM actors WHERE actor=?", actor)[1]
        return row and row.id
    end

    local function add(actor, start, role, text)
        assert(type(text) == "string" and text ~= "" and utf8.len(text), "record text must be valid nonempty text")
        return transaction(function()
            local owner = actor_id(actor, role == "user")
            assert(owner, "actor has no Store history")
            local id = rows("SELECT coalesce(max(id),0)+1 id FROM results")[1].id
            execute(INSERT, id, owner, start or id, role, tail(text, maximum))
            return one(" WHERE r.id=?", id)
        end)
    end

    local api = {}
    function api:begin(actor, request)
        return add(actor, nil, "user", request)
    end
    function api:append(actor, start, role, text)
        assert(role == "assistant" or role == "tool", "result role must be assistant or tool")
        return add(actor, assert(math.tointeger(start), "start must be an integer"), role, text)
    end
    function api:read(actor, start, id)
        return one(" WHERE a.actor=? AND r.id=? AND r.id<?", actor, id, start)
    end
    function api:around(actor, start, id)
        local current = self:read(actor, start, id)
        if not current then
            return nil
        end
        local previous = one(" WHERE a.actor=? AND r.id<? ORDER BY r.id DESC LIMIT 1", actor, id)
        local following = one(" WHERE a.actor=? AND r.id>? AND r.id<? ORDER BY r.id LIMIT 1", actor, id, start)
        return { previous = previous, current = current, next = following }
    end
    function api:before(actor, start, visit)
        local statement =
            assert(db:prepare(result_select .. " WHERE r.actor_id=? AND r.id<? ORDER BY r.id DESC"), db:errmsg())
        assert(statement:bind_values(actor_id(actor, false), start) == sqlite.OK, db:errmsg())
        local result = table.pack(pcall(function()
            for row in statement:nrows() do
                if visit(row) == false then
                    break
                end
            end
        end))
        assert(statement:finalize() == sqlite.OK, db:errmsg())
        assert(result[1], result[2])
    end
    function api:ground(value, term_maximum, token_maximum, exact_maximum)
        local terms, tokens, exact, seen = {}, {}, {}, {}
        for literal in value:gmatch("%S+") do
            if literal:find("_", 1, true) then
                assert(#exact < exact_maximum, "grounding text exceeds exact form limit")
                exact[#exact + 1] = literal
            end
            if not seen[literal:lower()] and #terms < term_maximum then
                terms[#terms + 1], seen[literal:lower()] = literal, true
            end
        end
        execute("DELETE FROM grounding_tokenizer")
        execute("INSERT INTO grounding_tokenizer(text) VALUES(?)", value)
        for _, row in ipairs(rows("SELECT term FROM grounding_vocabulary ORDER BY offset")) do
            assert(#tokens < token_maximum, "grounding text exceeds semantic input token limit")
            tokens[#tokens + 1] = row.term
            if not seen[row.term] and #terms < term_maximum then
                terms[#terms + 1], seen[row.term] = row.term, true
            end
        end
        return { terms = terms, tokens = tokens, exact_forms = exact }
    end
    function api:search(actor, start, terms, limit)
        local literals = {}
        for _, term in ipairs(terms) do
            literals[#literals + 1] = '"' .. term:gsub('"', '""') .. '"'
        end
        if #literals == 0 then
            return {}
        end
        local owner = actor_id(actor, false)
        local query = 'actor_id:"' .. owner .. '" AND (' .. table.concat(literals, " OR ") .. ")"
        return rows(SEARCH, query, owner, start, limit)
    end
    function api:close()
        assert(db:close() == sqlite.OK, "close Zinc Store failed")
    end
    return api
end
