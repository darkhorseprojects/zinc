local sqlite = require("lsqlite3complete")
local APPLICATION_ID, SCHEMA_VERSION = 1514753603, 3
local SELECT = "SELECT id,actor,coalesce(start,id) start,role,text FROM results"
local SEARCH = [[
SELECT r.id,r.actor,coalesce(r.start,r.id) start,r.role,r.text,bm25(result_fts) lexical_score
FROM result_fts JOIN results r ON r.id=result_fts.rowid
WHERE result_fts MATCH ? AND r.actor=? AND r.id<? ORDER BY lexical_score,r.id LIMIT ?
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

return function(path, maximum)
    assert(type(path) == "string" and path ~= "", "invalid Store path")
    maximum = assert(math.tointeger(maximum), "stored record budget must be an integer")
    assert(maximum >= 4, "stored record budget must be at least four bytes")
    local db = assert(sqlite.open(path))
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
        assert(statement:bind_values(...) == sqlite.OK and statement:step() == sqlite.DONE, db:errmsg())
        assert(statement:finalize() == sqlite.OK, db:errmsg())
    end
    local function one(where, ...)
        return rows(SELECT .. where, ...)[1]
    end

    assert(
        db:exec("PRAGMA trusted_schema=OFF; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL")
            == sqlite.OK,
        db:errmsg()
    )
    local identity = rows("PRAGMA application_id")[1].application_id
    local version = rows("PRAGMA user_version")[1].user_version
    if identity == 0 then
        assert(
            version == 0 and not rows("SELECT name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' LIMIT 1")[1],
            "Store database is not empty"
        )
    else
        assert(identity == APPLICATION_ID and version == SCHEMA_VERSION, "Store format is unsupported")
    end
    assert(db:exec(string.format(
        [[
CREATE TABLE IF NOT EXISTS results(
 id INTEGER PRIMARY KEY,actor TEXT NOT NULL,start INTEGER,
 role TEXT NOT NULL CHECK(role IN ('user','assistant','tool')),text TEXT NOT NULL CHECK(length(text)>0),
 UNIQUE(id,actor),FOREIGN KEY(start,actor) REFERENCES results(id,actor)
) STRICT;
CREATE INDEX IF NOT EXISTS results_by_actor ON results(actor,id);
CREATE VIRTUAL TABLE IF NOT EXISTS result_fts USING fts5(
 text,content='results',content_rowid='id',tokenize='unicode61 remove_diacritics 0'
);
CREATE TRIGGER IF NOT EXISTS results_fts_insert AFTER INSERT ON results BEGIN
 INSERT INTO result_fts(rowid,text) VALUES(new.id,new.text);
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

    local function add(actor, start, role, text)
        assert(type(actor) == "string" and actor ~= "" and utf8.len(actor), "actor must be valid nonempty text")
        assert(type(text) == "string" and text ~= "" and utf8.len(text), "record text must be valid nonempty text")
        execute("INSERT INTO results(actor,start,role,text) VALUES(?,?,?,?)", actor, start, role, tail(text, maximum))
        return one(" WHERE id=last_insert_rowid()")
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
        return one(" WHERE actor=? AND id=? AND id<?", actor, id, start)
    end
    function api:around(actor, start, id)
        local current = self:read(actor, start, id)
        if not current then
            return nil
        end
        return {
            previous = one(" WHERE actor=? AND id<? ORDER BY id DESC LIMIT 1", actor, id),
            current = current,
            next = one(" WHERE actor=? AND id>? AND id<? ORDER BY id LIMIT 1", actor, id, start),
        }
    end
    function api:before(actor, start, limit)
        return rows(SELECT .. " WHERE actor=? AND id<? ORDER BY id DESC LIMIT ?", actor, start, limit)
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
            assert(#tokens < token_maximum, "grounding text exceeds grounding token limit")
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
        return rows(SEARCH, table.concat(literals, " OR "), actor, start, limit)
    end
    return api
end
