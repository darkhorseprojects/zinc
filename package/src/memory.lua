local json = require("src.json")
local sqlite = require("lsqlite3complete")

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

local function rows(db, statement, ...)
    assert(statement:reset() == sqlite.OK, db:errmsg())
    assert(statement:bind_values(...) == sqlite.OK, db:errmsg())
    local output = {}
    for row in statement:nrows() do
        output[#output + 1] = row
    end
    return output
end

return function(config, store, model)
    local db = assert(sqlite.open(config.cygnet, sqlite.OPEN_READONLY))
    local opened, state = pcall(function()
        assert(db:exec("PRAGMA trusted_schema=OFF") == sqlite.OK, db:errmsg())
        local metadata = query(db, META)[1]
        local maximum = metadata and tonumber(metadata.value)
        assert(maximum and maximum > 0, "Cygnet format is unsupported")
        assert(db:exec([[
CREATE VIRTUAL TABLE temp.grounding_tokenizer USING fts5(text,tokenize='unicode61 remove_diacritics 0');
CREATE VIRTUAL TABLE temp.grounding_vocabulary USING fts5vocab(grounding_tokenizer,'instance');
]]) == sqlite.OK, db:errmsg())
        return {
            maximum = maximum,
            score = assert(db:prepare(SCORE), db:errmsg()),
            expand = assert(db:prepare(EXPAND), db:errmsg()),
        }
    end)
    if not opened then
        db:close()
        error(state, 0)
    end

    local function fits(records, maximum)
        local encoded = json.encode(records)
        return #encoded <= maximum or model:tokens(encoded) <= maximum
    end

    local function chronological(actor, boundary)
        local values = store:before(actor, boundary, config.chronological_records)
        local function prefix(count)
            local result = { [0] = count }
            for index = count, 1, -1 do
                result[#result + 1] = values[index]
            end
            return result
        end
        if fits(prefix(#values), config.chronological_tokens) then
            return prefix(#values)
        end
        local low, high = 0, #values
        while low + 1 < high do
            local middle = (low + high) // 2
            if fits(prefix(middle), config.chronological_tokens) then
                low = middle
            else
                high = middle
            end
        end
        return prefix(low)
    end

    local function ground(value)
        local terms, tokens, exact, seen = {}, {}, {}, {}
        for literal in value:gmatch("%S+") do
            if literal:find("_", 1, true) then
                assert(#exact < config.exact_forms, "grounding text exceeds exact form limit")
                exact[#exact + 1] = literal
            end
            local key = literal:lower()
            if not seen[key] and #terms < config.semantic_terms then
                terms[#terms + 1], seen[key] = literal, true
            end
        end
        assert(db:exec("DELETE FROM grounding_tokenizer") == sqlite.OK, db:errmsg())
        query(db, "INSERT INTO grounding_tokenizer(text) VALUES(?) RETURNING rowid", value)
        local vocabulary =
            query(db, "SELECT term FROM grounding_vocabulary ORDER BY offset LIMIT ?", config.grounding_tokens + 1)
        assert(#vocabulary <= config.grounding_tokens, "grounding text exceeds grounding token limit")
        for _, row in ipairs(vocabulary) do
            tokens[#tokens + 1] = row.term
            if not seen[row.term] and #terms < config.semantic_terms then
                terms[#terms + 1], seen[row.term] = row.term, true
            end
        end
        return terms, tokens, exact
    end

    local function expand(terms, tokens, exact)
        local forms, seen, offset = {}, {}, 1
        local function add(value)
            local form = value:lower():gsub("_", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
            local score = rows(db, state.score, config.semantic_language, form)[1]
            if not score then
                return false
            end
            local attention = -math.log(score.probability / score.normalization * score.vocabulary)
            if attention < config.semantic_attention_cutoff then
                return false
            end
            if not seen[form] then
                seen[form], forms[#forms + 1] = true, form
            end
            return true
        end
        while offset <= #tokens do
            local accepted = 0
            for count = math.min(state.maximum, #tokens - offset + 1), 1, -1 do
                if add(table.concat(tokens, " ", offset, offset + count - 1)) then
                    accepted = count
                    break
                end
            end
            offset = offset + math.max(accepted, 1)
        end
        for _, form in ipairs(exact) do
            add(form)
        end
        seen = {}
        for _, form in ipairs(forms) do
            local remaining = config.semantic_terms - #terms
            if remaining == 0 then
                break
            end
            for _, row in
                ipairs(
                    rows(
                        db,
                        state.expand,
                        config.semantic_language,
                        form,
                        config.semantic_depth,
                        config.semantic_language,
                        remaining
                    )
                )
            do
                local key = row.term:lower()
                if not seen[key] then
                    seen[key], terms[#terms + 1] = true, row.term
                end
            end
        end
    end

    local memory = {}
    function memory:context(actor, boundary, anchor)
        if boundary == 0 then
            return '{"chronological":[],"semantic":[]}'
        end
        local recent = chronological(actor, boundary)
        local terms, tokens, exact = ground(anchor)
        if #terms < config.semantic_terms then
            expand(terms, tokens, exact)
        end
        local excluded, candidates = {}, {}
        for _, record in ipairs(recent) do
            excluded[record.id] = true
        end
        for _, record in ipairs(store:search(actor, boundary, terms, config.candidates + #recent)) do
            if not excluded[record.id] and #candidates < config.candidates then
                excluded[record.id], candidates[#candidates + 1] = true, record
            end
        end
        local passages = {}
        for index, record in ipairs(candidates) do
            passages[index] = record.role .. ":\n" .. record.text
        end
        local semantic = {}
        for _, index in ipairs(model:rerank(anchor, passages)) do
            semantic[#semantic + 1] = candidates[index]
            if not fits(semantic, config.semantic_tokens) then
                semantic[#semantic] = nil
            end
        end
        semantic[0] = #semantic
        return json.encode({ chronological = recent, semantic = semantic })
    end

    function memory:close()
        local first = state.score:finalize()
        local second = state.expand:finalize()
        local third = db:close()
        assert(first == sqlite.OK and second == sqlite.OK and third == sqlite.OK, "failed to close Cygnet")
    end

    return memory
end
