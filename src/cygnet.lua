local sqlite = require("lsqlite3")

local CONTENT_POS = "'NOUN','VERB','ADJ','ADV'"
local EXPANSION_RELATIONS = {
    "pertainym",
    "derivation",
    "antonym",
    "participle",
    "also",
    "similar",
    "attribute",
    "hypernym",
    "hyponym",
    "mero_part",
    "holo_part",
    "mero_substance",
    "holo_substance",
    "mero_member",
    "holo_member",
    "meronym",
    "holonym",
    "entails",
    "is_entailed_by",
    "causes",
    "is_caused_by",
    "instance_hypernym",
    "instance_hyponym",
}

local function quote(value)
    return "'" .. value:gsub("'", "''") .. "'"
end

local function normalize(value)
    return value:lower():gsub("%s+", " "):match("^%s*(.-)%s*$")
end

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local module = {}

function module.open(config)
    assert(type(config) == "table", "Cygnet config is required")
    assert(type(config.source) == "string" and config.source ~= "", "Cygnet source path is required")
    assert(type(config.index) == "string" and config.index ~= "", "Cygnet index path is required")
    assert(
        type(config.source_identity) == "string" and config.source_identity ~= "",
        "Cygnet source identity is required"
    )
    local db = assert(sqlite.open(config.source, sqlite.OPEN_READONLY))
    db:busy_timeout(5000)
    assert(
        db:exec("PRAGMA automatic_index=OFF; ATTACH DATABASE " .. quote(config.index) .. " AS zinc_index") == sqlite.OK,
        db:errmsg()
    )

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

    local metadata = {}
    for _, row in ipairs(rows("SELECT key,value FROM zinc_index.metadata")) do
        metadata[row.key] = row.value
    end
    assert(metadata.format_version == "1", "Cygnet index format is unsupported")
    assert(metadata.source_identity == config.source_identity, "Cygnet source and index identities differ")
    assert(metadata.algorithm == "relation-balanced-pagerank-v1", "Cygnet index algorithm is unsupported")

    assert(db:exec([[
CREATE TEMP TABLE request_tokens(position INTEGER PRIMARY KEY,token TEXT NOT NULL);
CREATE TEMP TABLE matched_forms(normalized_form TEXT PRIMARY KEY) WITHOUT ROWID;
CREATE TEMP TABLE frontier(synset INTEGER PRIMARY KEY) WITHOUT ROWID;
CREATE TEMP TABLE visited(synset INTEGER PRIMARY KEY) WITHOUT ROWID;
CREATE TEMP TABLE next_frontier(synset INTEGER PRIMARY KEY) WITHOUT ROWID;
]]) == sqlite.OK, db:errmsg())

    local expansion_literals = {}
    for _, relation in ipairs(EXPANSION_RELATIONS) do
        expansion_literals[#expansion_literals + 1] = quote(relation)
    end
    local expansion_set = table.concat(expansion_literals, ",")

    local function language_statistics(language)
        return rows(
            [[SELECT normalization,vocabulary,maximum_form_tokens
FROM zinc_index.language_statistics WHERE language=?]],
            language
        )[1]
    end

    local function forms(tokens, exact_forms, language, statistics)
        execute("DELETE FROM request_tokens")
        local insert_token = assert(db:prepare("INSERT INTO request_tokens(position,token) VALUES(?,?)"), db:errmsg())
        for index, token in ipairs(tokens) do
            assert(insert_token:bind_values(index, token) == sqlite.OK, db:errmsg())
            assert(insert_token:step() == sqlite.DONE, db:errmsg())
            assert(insert_token:reset() == sqlite.OK, db:errmsg())
        end
        assert(insert_token:finalize() == sqlite.OK, db:errmsg())
        execute("DELETE FROM matched_forms")
        execute(
            [[
INSERT OR IGNORE INTO matched_forms
WITH RECURSIVE spans(start,stop,normalized_form) AS (
 SELECT position,position,token FROM request_tokens
 UNION ALL
 SELECT spans.start,next.position,spans.normalized_form||' '||next.token
 FROM spans JOIN request_tokens next ON next.position=spans.stop+1
 WHERE spans.stop-spans.start+1<?
)
SELECT DISTINCT spans.normalized_form FROM spans
CROSS JOIN forms f INDEXED BY idx_forms_normalized ON f.normalized_form=spans.normalized_form
]],
            statistics.maximum_form_tokens
        )
        local insert_form = assert(db:prepare("INSERT OR IGNORE INTO matched_forms VALUES(?)"), db:errmsg())
        for _, value in ipairs(exact_forms) do
            if value:find("_", 1, true) then
                assert(insert_form:bind_values(normalize(value)) == sqlite.OK, db:errmsg())
                assert(insert_form:step() == sqlite.DONE, db:errmsg())
                assert(insert_form:reset() == sqlite.OK, db:errmsg())
            end
        end
        assert(insert_form:finalize() == sqlite.OK, db:errmsg())

        local grouped = {}
        for _, row in
            ipairs(rows([[
SELECT DISTINCT f.normalized_form,s.synset_rowid,m.mass,c.count
FROM matched_forms matched
CROSS JOIN forms f INDEXED BY idx_forms_normalized ON f.normalized_form=matched.normalized_form
JOIN entries e ON e.rowid=f.entry_rowid JOIN languages l ON l.rowid=e.language_rowid
JOIN senses s ON s.entry_rowid=e.rowid
JOIN zinc_index.concept_mass m ON m.synset_rowid=s.synset_rowid
JOIN zinc_index.concept_form_counts c ON c.language=l.code AND c.synset_rowid=s.synset_rowid
WHERE l.code=? AND e.pos IN (]] .. CONTENT_POS .. [[)
ORDER BY f.normalized_form,s.synset_rowid
]], language))
        do
            local term = grouped[row.normalized_form]
            if not term then
                term = { concepts = {}, probability = 0 }
                grouped[row.normalized_form] = term
            end
            term.concepts[#term.concepts + 1] = row.synset_rowid
            term.probability = term.probability + row.mass / row.count
        end
        for _, term in pairs(grouped) do
            term.attention = -math.log(term.probability / statistics.normalization * statistics.vocabulary)
        end
        return grouped
    end

    local function select_terms(tokens, exact_forms, grouped, maximum_form_tokens, cutoff, language)
        local selected, seen, offset = {}, {}, 1
        while offset <= #tokens do
            local accepted, length
            for size = math.min(maximum_form_tokens, #tokens - offset + 1), 1, -1 do
                local normalized = normalize(table.concat(tokens, " ", offset, offset + size - 1))
                local term = grouped[normalized]
                if term and term.attention >= cutoff then
                    accepted, length = term, size
                    break
                end
            end
            if accepted then
                local key = table.concat(accepted.concepts, ",")
                if not seen[key] then
                    seen[key] = true
                    selected[#selected + 1] = { concepts = accepted.concepts, language = language }
                end
                offset = offset + length
            else
                offset = offset + 1
            end
        end
        for _, value in ipairs(exact_forms) do
            if value:find("_", 1, true) then
                local term = grouped[normalize(value)]
                if term and term.attention >= cutoff then
                    local key = table.concat(term.concepts, ",")
                    if not seen[key] then
                        seen[key] = true
                        selected[#selected + 1] = { concepts = term.concepts, language = language }
                    end
                end
            end
        end
        return selected
    end

    local function expansion(selected, depth, maximum)
        local output, output_seen = {}, {}
        for _, term in ipairs(selected) do
            execute("DELETE FROM frontier")
            execute("DELETE FROM visited")
            local insert = assert(db:prepare("INSERT INTO frontier VALUES(?)"), db:errmsg())
            for _, concept in ipairs(term.concepts) do
                assert(insert:bind_values(concept) == sqlite.OK, db:errmsg())
                assert(insert:step() == sqlite.DONE, db:errmsg())
                assert(insert:reset() == sqlite.OK, db:errmsg())
            end
            assert(insert:finalize() == sqlite.OK, db:errmsg())
            execute("INSERT INTO visited SELECT synset FROM frontier")
            for level = 0, depth do
                for _, row in
                    ipairs(rows([[
SELECT DISTINCT f.normalized_form FROM frontier q JOIN senses s ON s.synset_rowid=q.synset
JOIN entries e ON e.rowid=s.entry_rowid JOIN languages l ON l.rowid=e.language_rowid
JOIN forms f ON f.entry_rowid=e.rowid
WHERE l.code=? AND e.pos IN (]] .. CONTENT_POS .. [[) AND f.normalized_form<>'' ORDER BY f.normalized_form
]], term.language))
                do
                    local key = row.normalized_form:lower()
                    if not output_seen[key] then
                        output_seen[key] = true
                        output[#output + 1] = row.normalized_form
                        if #output == maximum then
                            return output
                        end
                    end
                end
                if level == depth then
                    break
                end
                execute("DELETE FROM next_frontier")
                execute(([[
INSERT OR IGNORE INTO next_frontier
SELECT r.target_rowid FROM synset_relations r JOIN frontier q ON q.synset=r.source_rowid
JOIN relation_types t ON t.rowid=r.type_rowid
WHERE t.type IN (%s) AND NOT EXISTS(SELECT 1 FROM visited v WHERE v.synset=r.target_rowid)
UNION
SELECT target.synset_rowid FROM sense_relations r
JOIN senses source ON source.rowid=r.source_rowid JOIN frontier q ON q.synset=source.synset_rowid
JOIN senses target ON target.rowid=r.target_rowid JOIN relation_types t ON t.rowid=r.type_rowid
WHERE t.type IN (%s) AND NOT EXISTS(SELECT 1 FROM visited v WHERE v.synset=target.synset_rowid)
]]):format(expansion_set, expansion_set))
                if #rows("SELECT synset FROM next_frontier LIMIT 1") == 0 then
                    break
                end
                execute("INSERT OR IGNORE INTO visited SELECT synset FROM next_frontier")
                execute("DELETE FROM frontier")
                execute("INSERT INTO frontier SELECT synset FROM next_frontier")
            end
        end
        return output
    end

    local api = {}

    function api:expand(request)
        assert(type(request) == "table", "Cygnet request must be a table")
        assert(type(request.tokens) == "table" and type(request.exact_forms) == "table", "Cygnet forms are invalid")
        for _, token in ipairs(request.tokens) do
            assert(
                type(token) == "string" and token ~= "" and not token:find("%s") and not token:find("%z"),
                "Cygnet token is invalid"
            )
        end
        for _, value in ipairs(request.exact_forms) do
            assert(type(value) == "string" and value ~= "" and not value:find("%z"), "Cygnet exact form is invalid")
        end
        local depth = assert(math.tointeger(request.semantic_depth), "Cygnet depth must be an integer")
        local maximum = assert(math.tointeger(request.maximum_terms), "Cygnet term limit must be an integer")
        local cutoff = request.semantic_attention_cutoff
        assert(depth >= 0 and depth <= 4, "Cygnet depth must be from zero to four")
        assert(maximum >= 1 and maximum <= 4096, "Cygnet term limit must be from one to 4096")
        assert(finite(cutoff), "Cygnet attention cutoff must be finite")
        local statistics = assert(language_statistics(request.semantic_language), "Cygnet language is unsupported")
        local grouped = forms(request.tokens, request.exact_forms, request.semantic_language, statistics)
        local selected = select_terms(
            request.tokens,
            request.exact_forms,
            grouped,
            statistics.maximum_form_tokens,
            cutoff,
            request.semantic_language
        )
        return expansion(selected, depth, maximum)
    end

    function api:close()
        assert(db:close() == sqlite.OK, "closing Cygnet failed")
    end

    return api
end

return module
