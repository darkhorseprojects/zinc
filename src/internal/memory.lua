local sqlite = require("lsqlite3complete")
local SELECT = "SELECT id,actor,coalesce(start,id) start,role,text FROM results"
local SEARCH = [[SELECT r.id,r.actor,coalesce(r.start,r.id) start,r.role,r.text,bm25(result_fts) lexical_score
FROM result_fts JOIN results r ON r.id=result_fts.rowid
WHERE result_fts MATCH ? AND r.actor=? AND r.id<? ORDER BY lexical_score,r.id LIMIT ?]]
local EXPAND = [[WITH RECURSIVE reachable(concept,depth) AS (
 SELECT concept,0 FROM form_concepts WHERE language=? AND form=?
 UNION SELECT e.target,r.depth+1 FROM reachable r JOIN concept_edges e ON e.source=r.concept WHERE r.depth<?)
SELECT t.term,min(r.depth) depth FROM reachable r JOIN concept_terms t ON t.concept=r.concept
WHERE t.language=? GROUP BY t.term ORDER BY depth,t.term LIMIT ?]]
local SCORE = [[SELECT s.probability,l.normalization,l.vocabulary FROM form_scores s
JOIN languages l ON l.language=s.language WHERE s.language=? AND s.form=?
AND EXISTS(SELECT 1 FROM form_concepts c WHERE c.language=s.language AND c.form=s.form)]]
local META = [[SELECT value FROM metadata WHERE key='maximum_form_tokens'
AND EXISTS(SELECT 1 FROM metadata WHERE key='format_version' AND value='2')
AND EXISTS(SELECT 1 FROM metadata WHERE key='algorithm' AND value='relation-balanced-pagerank-v1')]]

local function query(db, sql, ...)
    local statement = assert(db:prepare(sql), db:errmsg())
    local result = table.pack(pcall(function(...)
        assert(statement:bind_values(...) == sqlite.OK, db:errmsg())
        local rows = {}
        for row in statement:nrows() do rows[#rows + 1] = row end
        return rows
    end, ...))
    local finalized = statement:finalize()
    if not result[1] then error(result[2], 0) end
    assert(finalized == sqlite.OK, db:errmsg())
    return result[2]
end

local function tail(value, maximum)
    if not maximum or #value <= maximum then return value end
    return (value:sub(-maximum):gsub("^[\128-\191]*", ""))
end

local function open_store(path)
    assert(type(path) == "string" and path ~= "", "invalid Store path")
    local db = assert(sqlite.open(path))
    assert(
        db:exec("PRAGMA trusted_schema=OFF; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL") ==
        sqlite.OK, db:errmsg())
    local version = query(db, "PRAGMA user_version")[1].user_version
    assert(version == 0 or version == 3, "Store format is unsupported")
    assert(db:exec(string.format([[
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
PRAGMA user_version=%d;
]], 3)) == sqlite.OK, db:errmsg())
    assert(db:exec([[
CREATE VIRTUAL TABLE temp.grounding_tokenizer USING fts5(text,tokenize='unicode61 remove_diacritics 0');
CREATE VIRTUAL TABLE temp.grounding_vocabulary USING fts5vocab(grounding_tokenizer,'instance');
]]) == sqlite.OK, db:errmsg())
    local function one(where, ...) return query(db, SELECT .. where, ...)[1] end
    local function add(actor, start, role, text, maximum)
        assert(type(actor) == "string" and actor ~= "" and type(text) == "string" and text ~= "" and utf8.len(text),
            "invalid record")
        return query(db, [[INSERT INTO results(actor,start,role,text) VALUES(?,?,?,?)
RETURNING id,actor,coalesce(start,id) start,role,text]], actor, start, role, tail(text, maximum))[1]
    end
    local store = {}
    function store:begin(actor, request, maximum) return add(actor, nil, "user", request, maximum) end

    function store:append(actor, start, role, text, maximum)
        return add(actor,
            assert(math.tointeger(start), "start must be an integer"), role, text, maximum)
    end

    function store:read(actor, start, id) return one(" WHERE actor=? AND id=? AND id<?", actor, id, start) end

    function store:around(actor, start, id)
        local current = self:read(actor, start, id)
        if not current then return nil end
        return {
            previous = one(" WHERE actor=? AND id<? ORDER BY id DESC LIMIT 1", actor, id),
            current = current,
            next =
                one(" WHERE actor=? AND id>? AND id<? ORDER BY id LIMIT 1", actor, id, start)
        }
    end

    function store:before(actor, start, limit)
        return query(db,
            SELECT .. " WHERE actor=? AND id<? ORDER BY id DESC LIMIT ?", actor, start, limit or -1)
    end

    function store:ground(value, term_maximum, token_maximum, exact_maximum)
        local terms, tokens, exact, seen = {}, {}, {}, {}
        for literal in value:gmatch("%S+") do
            if literal:find("_", 1, true) then
                assert(not exact_maximum or #exact < exact_maximum, "grounding text exceeds exact form limit")
                exact[#exact + 1] = literal
            end
            if not seen[literal:lower()] and (not term_maximum or #terms < term_maximum) then
                terms[#terms + 1], seen[literal:lower()] =
                    literal, true
            end
        end
        assert(db:exec("DELETE FROM grounding_tokenizer") == sqlite.OK, db:errmsg())
        query(db, "INSERT INTO grounding_tokenizer(text) VALUES(?) RETURNING rowid", value)
        for _, row in ipairs(query(db, "SELECT term FROM grounding_vocabulary ORDER BY offset")) do
            assert(not token_maximum or #tokens < token_maximum, "grounding text exceeds grounding token limit")
            tokens[#tokens + 1] = row.term
            if not seen[row.term] and (not term_maximum or #terms < term_maximum) then
                terms[#terms + 1], seen[row.term] =
                    row.term, true
            end
        end
        return { terms = terms, tokens = tokens, exact_forms = exact }
    end

    function store:search(actor, start, terms, limit)
        local literals = {}
        for _, term in ipairs(terms) do literals[#literals + 1] = '"' .. term:gsub('"', '""') .. '"' end
        if #literals == 0 then return {} end
        return query(db, SEARCH, table.concat(literals, " OR "), actor, start, limit or -1)
    end

    return store
end

local function open_cygnet(path)
    local db = assert(sqlite.open(assert(path), sqlite.OPEN_READONLY))
    local metadata = query(db, META)[1]
    local maximum = assert(metadata and tonumber(metadata.value), "Cygnet format is unsupported")
    local function recognized(form, request)
        local score = query(db, SCORE, request.semantic_language, form)[1]
        return score and
            -math.log(score.probability / score.normalization * score.vocabulary) >= request.semantic_attention_cutoff
    end
    return function(request)
        local forms, seen, offset = {}, {}, 1
        local function add(value)
            local form = value:lower():gsub("_", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
            if not recognized(form, request) then return false end
            if not seen[form] then seen[form], forms[#forms + 1] = true, form end
            return true
        end
        while offset <= #request.tokens do
            local accepted = 0
            for count = math.min(maximum, #request.tokens - offset + 1), 1, -1 do
                if add(table.concat(request.tokens, " ", offset, offset + count - 1)) then
                    accepted = count
                    break
                end
            end
            offset = offset + math.max(accepted, 1)
        end
        for _, form in ipairs(request.exact_forms) do add(form) end
        local output = {}; seen = {}
        for _, form in ipairs(forms) do
            local remaining = request.maximum_terms and request.maximum_terms - #output or -1
            if remaining == 0 then break end
            for _, row in ipairs(query(db, EXPAND, request.semantic_language, form, request.semantic_depth, request.semantic_language, remaining)) do
                local key = row.term:lower()
                if not seen[key] then seen[key], output[#output + 1] = true, row.term end
            end
        end
        return output
    end
end

local function retrieval(config, store, model, expand)
    local function fits(records, maximum, limits)
        return not maximum or
            model:tokens(model:encode(records), limits) <= maximum
    end
    local function recent(actor, start, limits)
        local maximum, result = limits.chronological_tokens, {}
        for _, value in ipairs(store:before(actor, start, limits.chronological_records)) do
            table.insert(result, 1, { id = value.id, role = value.role, text = value.text })
            if not fits(result, maximum, limits.runtime) then
                table.remove(result, 1)
                break
            end
        end
        return result
    end
    return function(actor, start, anchor, limits)
        local bounds = limits.retrieval or {}
        local request = {
            runtime = limits,
            chronological_records = bounds.chronological_records,
            chronological_tokens =
                bounds.chronological_tokens
        }
        local chronological = recent(actor, start, request)
        local grounded = store:ground(anchor, bounds.semantic_terms, bounds.grounding_tokens, bounds.exact_forms)
        local remaining = bounds.semantic_terms and bounds.semantic_terms - #grounded.terms
        if not remaining or remaining > 0 then
            for _, term in ipairs(expand({ tokens = grounded.tokens, exact_forms = grounded.exact_forms, semantic_language = config.semantic_language, semantic_depth = config.semantic_depth, semantic_attention_cutoff = config.semantic_attention_cutoff, maximum_terms = remaining })) do
                grounded.terms[#grounded.terms + 1] =
                    term
            end
        end
        local excluded, candidates = {}, {}
        for _, record in ipairs(chronological) do excluded[record.id] = true end
        for _, record in ipairs(store:search(actor, start, grounded.terms, bounds.candidates)) do
            if not excluded[record.id] then
                excluded[record.id] = true; candidates[#candidates + 1] = {
                    id = record.id,
                    role = record.role,
                    text =
                        record.text
                }
            end
        end
        local passages = {}; for index, record in ipairs(candidates) do
            passages[index] = record.role ..
                ":\n" .. record.text
        end
        local semantic = {}
        for _, index in ipairs(model:rerank(anchor, passages, limits)) do
            semantic[#semantic + 1] = candidates[index]
            if not fits(semantic, bounds.semantic_tokens, limits) then
                semantic[#semantic] = nil
                break
            end
        end
        chronological[0], semantic[0] = #chronological, #semantic
        return model:encode({ chronological = chronological, semantic = semantic })
    end
end

return function(config, model)
    if not config.store then return nil end
    local store = open_store(config.store)
    local context = retrieval(config.retrieval, store, model, open_cygnet(config.cygnet))
    local memory = {}
    function memory:begin(actor, request, maximum) return store:begin(actor, request, maximum) end

    function memory:append(actor, start, role, text, maximum) return store:append(actor, start, role, text, maximum) end

    function memory:read(actor, start, id) return store:read(actor, start, id) end

    function memory:around(actor, start, id) return store:around(actor, start, id) end

    function memory:context(actor, start, anchor, limits) return context(actor, start, anchor, limits) end

    return memory
end
