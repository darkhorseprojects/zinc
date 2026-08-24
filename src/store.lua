local sqlite = require("lsqlite3")
local uv = require("luv")

local APPLICATION_ID = 1514753603
local SCHEMA_VERSION = 2

local function mkdir(path)
    if uv.fs_stat(path) then
        return
    end
    local parent = path:match("^(.*)[/\\][^/\\]+$")
    if parent and parent ~= "" and parent ~= path then
        mkdir(parent)
    end
    local ok, failure, code = uv.fs_mkdir(path, 448)
    assert(ok or code == "EEXIST" and uv.fs_stat(path), failure)
end

local function tail(value, maximum)
    if #value <= maximum then
        return value
    end
    local first = #value - maximum + 1
    while first <= #value and value:byte(first) >= 128 and value:byte(first) < 192 do
        first = first + 1
    end
    return value:sub(first)
end

local function actor(value)
    assert(type(value) == "string" and value ~= "", "actor must be nonempty text")
    assert(utf8.len(value), "actor must be valid UTF-8")
    return value
end

local function package_path(directory, path, separator)
    assert(type(directory) == "string" and directory ~= "", "package directory is required")
    directory = assert(uv.fs_realpath(directory), "package directory does not exist")
    assert(type(path) == "string" and path ~= "", "Store path is required")
    assert(
        not path:find("\\", 1, true) and path:sub(1, 1) ~= "/" and not path:match("^%a:"),
        "Store path must be package-relative"
    )
    local parts = {}
    for part in path:gmatch("[^/]+") do
        assert(part ~= "." and part ~= "..", "Store path must not contain traversal")
        parts[#parts + 1] = part
    end
    assert(#parts > 1 and table.concat(parts, "/") == path, "Store path must contain a directory and file")
    return directory .. separator .. table.concat(parts, separator)
end

local function integer(value, what)
    local converted = math.tointeger(value)
    assert(converted, what .. " must be an integer")
    return converted
end

local function text(value, what)
    assert(type(value) == "string" and value ~= "", what .. " must be nonempty text")
    assert(utf8.len(value), what .. " must be valid UTF-8")
    return value
end

local module = {}

function module.open(config)
    local maximum = integer(config.max_stored_record_bytes, "stored record budget")
    assert(maximum >= 4, "stored record budget must be at least four bytes")
    local separator = package.config:sub(1, 1)
    local path = package_path(config.package_directory, config.path, separator)
    local directory = assert(path:match("^(.*)[/\\][^/\\]+$"), "Store path has no parent")
    mkdir(directory)
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
        assert(statement:bind_values(...) == sqlite.OK, db:errmsg())
        local code = statement:step()
        assert(statement:finalize() == sqlite.OK, db:errmsg())
        assert(code == sqlite.DONE, db:errmsg())
    end

    local function transaction(work)
        assert(db:exec("BEGIN IMMEDIATE") == sqlite.OK, db:errmsg())
        local result = table.pack(pcall(work))
        if not result[1] then
            db:exec("ROLLBACK")
            error(result[2], 0)
        end
        if db:exec("COMMIT") ~= sqlite.OK then
            local failure = db:errmsg()
            db:exec("ROLLBACK")
            error(failure, 0)
        end
        return table.unpack(result, 2, result.n)
    end

    assert(
        db:exec("PRAGMA trusted_schema=OFF; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;") == sqlite.OK,
        db:errmsg()
    )
    local deadline, journal = uv.hrtime() + 5000000000
    repeat
        journal = db:exec("PRAGMA journal_mode=WAL")
        if journal == sqlite.BUSY or journal == sqlite.LOCKED then
            uv.sleep(1)
        end
    until journal ~= sqlite.BUSY and journal ~= sqlite.LOCKED or uv.hrtime() >= deadline
    assert(journal == sqlite.OK, db:errmsg())

    assert(db:exec("BEGIN IMMEDIATE") == sqlite.OK, db:errmsg())
    local application_id = rows("PRAGMA application_id")[1].application_id
    local schema_version = rows("PRAGMA user_version")[1].user_version
    local existing = rows("SELECT name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' LIMIT 1")
    if application_id == 0 and schema_version == 0 then
        assert(#existing == 0, "Store database is not empty")
    else
        assert(application_id == APPLICATION_ID, "Store application ID is unsupported")
        assert(schema_version == SCHEMA_VERSION, "Store schema version is unsupported")
    end

    assert(db:exec(string.format(
        [[
CREATE TABLE IF NOT EXISTS actors(
    id INTEGER PRIMARY KEY,
    actor TEXT NOT NULL UNIQUE
) STRICT;
CREATE TABLE IF NOT EXISTS results(
    id INTEGER PRIMARY KEY,
    actor_id INTEGER NOT NULL REFERENCES actors(id),
    start INTEGER NOT NULL,
    role TEXT NOT NULL CHECK(role IN ('user','assistant','tool')),
    text TEXT NOT NULL CHECK(length(text) > 0),
    UNIQUE(id,actor_id),
    FOREIGN KEY(start,actor_id) REFERENCES results(id,actor_id),
    CHECK((role='user' AND id=start) OR (role<>'user' AND id<>start))
) STRICT;
CREATE INDEX IF NOT EXISTS results_by_actor_id ON results(actor_id,id);
CREATE INDEX IF NOT EXISTS results_by_actor_start_id ON results(actor_id,start,id);
CREATE VIRTUAL TABLE IF NOT EXISTS result_fts USING fts5(
    actor_id,
    text,
    content='results',
    content_rowid='id',
    tokenize='unicode61 remove_diacritics 0'
);
CREATE TRIGGER IF NOT EXISTS results_fts_insert AFTER INSERT ON results BEGIN
    INSERT INTO result_fts(rowid,actor_id,text) VALUES(new.id,new.actor_id,new.text);
END;
PRAGMA application_id=%d;
PRAGMA user_version=%d;
]],
        APPLICATION_ID,
        SCHEMA_VERSION
    )) == sqlite.OK, db:errmsg())
    assert(db:exec("COMMIT") == sqlite.OK, db:errmsg())
    assert(db:exec([[
CREATE VIRTUAL TABLE temp.grounding_tokenizer
USING fts5(text,tokenize='unicode61 remove_diacritics 0');
CREATE VIRTUAL TABLE temp.grounding_vocabulary
USING fts5vocab(grounding_tokenizer,'instance');
]]) == sqlite.OK, db:errmsg())

    local function actor_id(who, create)
        who = actor(who)
        if create then
            execute("INSERT OR IGNORE INTO actors(actor) VALUES(?)", who)
        end
        local identity = rows("SELECT id FROM actors WHERE actor=?", who)[1]
        assert(identity, "actor has no Store history")
        return identity.id
    end

    local function record(id)
        return rows(
            "SELECT r.id,a.actor,r.start,r.role,r.text FROM results r JOIN actors a ON a.id=r.actor_id WHERE r.id=?",
            id
        )[1]
    end

    local function insert(who, start, role, value)
        value = tail(text(value, "record text"), maximum)
        execute(
            "INSERT INTO results(actor_id,start,role,text) VALUES(?,?,?,?)",
            actor_id(who, false),
            start,
            role,
            value
        )
        return record(db:last_insert_rowid())
    end

    local api = {}

    function api:ground(value, maximum_terms, maximum_tokens, maximum_exact_forms)
        value = text(value, "grounding text")
        maximum_terms = integer(maximum_terms, "grounding term limit")
        maximum_tokens = integer(maximum_tokens, "semantic input token limit")
        maximum_exact_forms = integer(maximum_exact_forms, "exact form limit")
        assert(maximum_terms > 0, "grounding term limit must be positive")
        assert(maximum_tokens > 0, "semantic input token limit must be positive")
        assert(maximum_exact_forms > 0, "exact form limit must be positive")
        local terms, tokens, exact_forms, seen = {}, {}, {}, {}
        for literal in value:gmatch("%S+") do
            if literal:find("_", 1, true) then
                assert(#exact_forms < maximum_exact_forms, "grounding text exceeds exact form limit")
                exact_forms[#exact_forms + 1] = literal
            end
            local key = literal:lower()
            if not seen[key] then
                seen[key] = true
                if #terms < maximum_terms then
                    terms[#terms + 1] = literal
                end
            end
        end
        execute("DELETE FROM grounding_tokenizer")
        execute("INSERT INTO grounding_tokenizer(text) VALUES(?)", value)
        for _, row in ipairs(rows("SELECT term FROM grounding_vocabulary ORDER BY offset")) do
            assert(#tokens < maximum_tokens, "grounding text exceeds semantic input token limit")
            tokens[#tokens + 1] = row.term
            if not seen[row.term] then
                seen[row.term] = true
                if #terms < maximum_terms then
                    terms[#terms + 1] = row.term
                end
            end
        end
        return { terms = terms, tokens = tokens, exact_forms = exact_forms }
    end

    function api:begin(who, request)
        who, request = actor(who), text(request, "request")
        local value = tail(request, maximum)
        return transaction(function()
            local identity = actor_id(who, true)
            local id = rows("SELECT coalesce(max(id),0)+1 id FROM results")[1].id
            execute("INSERT INTO results(id,actor_id,start,role,text) VALUES(?,?,?,'user',?)", id, identity, id, value)
            return record(id)
        end)
    end

    function api:append(who, start, role, value)
        start = integer(start, "start")
        assert(role == "assistant" or role == "tool", "result role must be assistant or tool")
        return insert(who, start, role, value)
    end

    function api:read(who, start, id)
        local identity = actor_id(who, false)
        return rows(
            [[SELECT r.id,a.actor,r.start,r.role,r.text
FROM results r JOIN actors a ON a.id=r.actor_id
WHERE r.actor_id=? AND r.id=? AND r.id<?]],
            identity,
            integer(id, "result id"),
            integer(start, "start")
        )[1]
    end

    function api:around(who, start, id)
        who, start, id = actor(who), integer(start, "start"), integer(id, "result id")
        local current = self:read(who, start, id)
        if not current then
            return nil
        end
        local identity = actor_id(who, false)
        local previous = rows(
            [[SELECT r.id,a.actor,r.start,r.role,r.text FROM results r JOIN actors a ON a.id=r.actor_id
WHERE r.actor_id=? AND r.id<? ORDER BY r.id DESC LIMIT 1]],
            identity,
            id
        )[1]
        local following = rows(
            [[SELECT r.id,a.actor,r.start,r.role,r.text FROM results r JOIN actors a ON a.id=r.actor_id
WHERE r.actor_id=? AND r.id>? AND r.id<? ORDER BY r.id LIMIT 1]],
            identity,
            id,
            start
        )[1]
        return { previous = previous, current = current, next = following }
    end

    function api:before(who, start, visit)
        who, start = actor(who), integer(start, "start")
        assert(type(visit) == "function", "history visitor must be a function")
        local statement = assert(
            db:prepare([[SELECT r.id,a.actor,r.start,r.role,r.text FROM results r JOIN actors a ON a.id=r.actor_id
WHERE r.actor_id=? AND r.id<? ORDER BY r.id DESC]]),
            db:errmsg()
        )
        assert(statement:bind_values(actor_id(who, false), start) == sqlite.OK, db:errmsg())
        local result = table.pack(pcall(function()
            for row in statement:nrows() do
                if visit(row) == false then
                    break
                end
            end
        end))
        local finalized = statement:finalize()
        assert(finalized == sqlite.OK, db:errmsg())
        if not result[1] then
            error(result[2], 0)
        end
    end

    function api:search(who, start, terms, limit)
        who, start = actor(who), integer(start, "start")
        limit = integer(limit, "search result limit")
        assert(limit > 0, "search result limit must be positive")
        assert(type(terms) == "table", "search terms must be a table")
        local literals, seen = {}, {}
        for _, term in ipairs(terms) do
            assert(type(term) == "string", "search term must be text")
            local normalized = term:match("^%s*(.-)%s*$")
            local key = normalized:lower()
            if normalized ~= "" and not seen[key] then
                seen[key] = true
                literals[#literals + 1] = '"' .. normalized:gsub('"', '""') .. '"'
            end
        end
        if #literals == 0 then
            return {}
        end
        local identity = actor_id(who, false)
        local query = 'actor_id:"' .. identity .. '" AND (' .. table.concat(literals, " OR ") .. ")"
        return rows(
            [[
SELECT r.id,a.actor,r.start,r.role,r.text,bm25(result_fts,0.0,1.0) lexical_score
FROM result_fts JOIN results r ON r.id=result_fts.rowid JOIN actors a ON a.id=r.actor_id
WHERE result_fts MATCH ? AND r.actor_id=? AND r.id<?
ORDER BY lexical_score,r.id
LIMIT ?
]],
            query,
            identity,
            start,
            limit
        )
    end

    function api:close()
        assert(db:close() == sqlite.OK, "close Zinc Store failed")
    end

    return api
end

return module
