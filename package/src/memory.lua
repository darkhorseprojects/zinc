local encode_json = require("lunajson.encoder")()
local sqlite = require("lsqlite3complete")

local EXPAND = [[WITH RECURSIVE reachable(concept,depth) AS (
 SELECT concept,0 FROM form_concepts WHERE language=? AND form=?
 UNION SELECT e.target,r.depth+1 FROM reachable r JOIN concept_edges e ON e.source=r.concept WHERE r.depth<?)
SELECT t.form term,min(r.depth) depth FROM reachable r JOIN form_concepts t ON t.concept=r.concept
WHERE t.language=? GROUP BY t.form ORDER BY depth,t.form LIMIT ?]]
local META = [[SELECT value FROM metadata WHERE key='maximum_form_tokens'
AND EXISTS(SELECT 1 FROM metadata WHERE key='format_version' AND value='4')]]

local function distance(a, right, maximum)
    local b = {}
    for _, code in utf8.codes(right) do
        b[#b + 1] = code
    end
    if math.abs(#a - #b) > maximum then
        return maximum + 1
    end
    local previous, current, prior = {}, {}, {}
    for j = 0, #b do
        previous[j] = j
    end
    for i = 1, #a do
        current[0] = i
        local minimum = current[0]
        for j = 1, #b do
            local cost = a[i] == b[j] and 0 or 1
            current[j] = math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            if i > 1 and j > 1 and a[i] == b[j - 1] and a[i - 1] == b[j] then
                current[j] = math.min(current[j], prior[j - 2] + 1)
            end
            minimum = math.min(minimum, current[j])
        end
        if minimum > maximum then
            return maximum + 1
        end
        prior, previous, current = previous, current, prior
    end
    return previous[#b]
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

return function(config, store, model)
    local db
    local state, memory = {}, {}

    function memory:close(original)
        if not db then
            return
        end
        local problem
        for _, statement in pairs(state) do
            if type(statement) == "userdata" and statement:finalize() ~= sqlite.OK then
                problem = problem or db:errmsg()
            end
        end
        local closed = db:close()
        if original == nil then
            assert(not problem, problem)
            assert(closed == sqlite.OK, "failed to close Cygnet")
        end
    end

    local function fitting(values, maximum, reverse)
        local output, bytes = { [0] = 0 }, 2
        for _, record in ipairs(values) do
            local size = #encode_json(record) + (output[0] > 0 and 1 or 0)
            if bytes + size > maximum then
                break
            end
            bytes = bytes + size
            output[0] = output[0] + 1
            output[output[0]] = record
        end
        if reverse then
            for index = 1, output[0] // 2 do
                local opposite = output[0] - index + 1
                output[index], output[opposite] = output[opposite], output[index]
            end
        end
        return output
    end

    local function ground(value, event)
        local terms, tokens, seen = {}, {}, {}
        for literal in value:gmatch("%S+") do
            if literal:find("_", 1, true) and literal:match("%w") and #terms < config.semantic.terms then
                local form = literal:lower()
                if not seen[form] then
                    seen[form], terms[#terms + 1] = true, form
                end
            end
        end
        for _, row in ipairs(store:tokens(event, config.semantic.terms)) do
            tokens[#tokens + 1] = row.term
            if not seen[row.term] and #terms < config.semantic.terms then
                seen[row.term], terms[#terms + 1] = true, row.term
            end
        end
        return terms, tokens
    end

    function memory:context(actor, boundary, branch, anchor, run, event)
        if boundary == 0 then
            return '{"chronological":[],"semantic":[]}'
        end
        local recent = fitting(
            store:before(actor, boundary, branch, config.chronological.records),
            config.chronological.bytes,
            true
        )
        local semantic = config.semantic
        if semantic.bytes == 0 or semantic.terms == 0 or semantic.candidates == 0 then
            return encode_json({ chronological = recent, semantic = { [0] = 0 } })
        end
        if not db then
            db = assert(sqlite.open(config.cygnet, sqlite.OPEN_READONLY))
            assert(db:exec("PRAGMA trusted_schema=OFF") == sqlite.OK, db:errmsg())
            local maximum
            for row in db:nrows(META) do
                maximum = tonumber(row.value)
            end
            assert(maximum and maximum > 0, "Cygnet format is unsupported")
            state.maximum = maximum
            state.form =
                assert(db:prepare("SELECT 1 FROM form_concepts WHERE language=? AND form=? LIMIT 1"), db:errmsg())
            state.expand = assert(db:prepare(EXPAND), db:errmsg())
        end
        local terms, tokens = ground(anchor, event)
        local groups, rarest = {}, 32
        for _, term in ipairs(terms) do
            local characters, grams, seen = {}, {}, {}
            for _, code in utf8.codes(term) do
                characters[#characters + 1] = code
            end
            if #characters >= 5 and #characters <= 32 then
                for index = 1, #characters - 2 do
                    local gram = utf8.char(characters[index], characters[index + 1], characters[index + 2])
                    if not seen[gram] then
                        seen[gram], grams[#grams + 1] = true, '"' .. gram:gsub('"', '""') .. '"'
                    end
                end
            end
            local best = { original = term, term = term, edits = math.huge, hits = 0 }
            local maximum = #characters >= 8 and 2 or 1
            local lexemes, exact_hits =
                store:lexemes(actor, boundary, branch, term, table.concat(grams, " OR "), semantic.candidates)
            for _, row in ipairs(lexemes) do
                local edits = row.term == term and 0 or distance(characters, row.term, maximum)
                if edits <= maximum then
                    local hits = row.term == term and exact_hits or store:frequency(actor, boundary, branch, row.id)
                    if
                        hits > 0
                        and (
                            edits < best.edits
                            or edits == best.edits
                                and (hits < best.hits or hits == best.hits and row.term < best.term)
                        )
                    then
                        best.term, best.edits, best.hits = row.term, edits, hits
                    end
                end
            end
            if best.hits > 0 then
                rarest = math.min(rarest, best.hits)
            end
            groups[#groups + 1] = best
        end
        table.sort(groups, function(a, b)
            if (a.hits == 0) ~= (b.hits == 0) then
                return a.hits > 0
            end
            if a.hits ~= b.hits then
                return a.hits < b.hits
            end
            return #a.original > #b.original
        end)
        local selected, words, word_seen, count = {}, {}, {}, 0
        for _, group in ipairs(groups) do
            if count == 4 or #words >= math.min(semantic.terms, semantic.candidates) then
                break
            end
            if group.hits == 0 or group.hits <= rarest * 4 then
                selected[group.original] = group.term
                count = count + 1
                if group.hits > 0 and not word_seen[group.term] then
                    word_seen[group.term], words[#words + 1] = true, group.term
                end
            end
        end
        local resolved = {}
        for index, token in ipairs(tokens) do
            resolved[index] = selected[token] or token
        end
        local offset = 1
        while count > 0 and offset <= #resolved and #words < math.min(semantic.terms, semantic.candidates) do
            local accepted = 0
            for width = math.min(state.maximum, #resolved - offset + 1), 1, -1 do
                local form = table.concat(resolved, " ", offset, offset + width - 1)
                if rows(db, state.form, semantic.language, form)[1] then
                    accepted = width
                    local eligible = false
                    for index = offset, offset + width - 1 do
                        eligible = eligible or selected[tokens[index]] ~= nil
                    end
                    if eligible then
                        local expanded = rows(
                            db,
                            state.expand,
                            semantic.language,
                            form,
                            semantic.depth,
                            semantic.language,
                            math.min(semantic.terms, semantic.candidates)
                        )
                        for _, row in ipairs(expanded) do
                            local synonym = row.term
                            local available = synonym:find(" ", 1, true) ~= nil
                            if not available then
                                local _, hits = store:lexemes(actor, boundary, branch, synonym, "", 0)
                                available = hits > 0
                            end
                            if available and not word_seen[synonym] then
                                word_seen[synonym], words[#words + 1] = true, synonym
                                if #words == math.min(semantic.terms, semantic.candidates) then
                                    break
                                end
                            end
                        end
                    end
                    break
                end
            end
            offset = offset + math.max(accepted, 1)
        end
        local excluded, candidates = {}, {}
        for _, record in ipairs(recent) do
            excluded[record.id] = true
        end
        if #words > 0 then
            for _, record in ipairs(store:search(actor, boundary, branch, words, semantic.candidates + #recent)) do
                if not excluded[record.id] and #candidates < semantic.candidates then
                    excluded[record.id], candidates[#candidates + 1] = true, record
                end
            end
        end
        local passages = {}
        for index, record in ipairs(candidates) do
            passages[index] = record.kind .. ":\n" .. record.text
        end
        local ranked = {}
        if #passages > 0 then
            assert(store:quota(run) > 0, "model quota exhausted")
            local results, usage, problem = model:rerank(anchor, passages)
            store:charge(run, usage)
            assert(not problem, problem)
            for _, result in ipairs(results) do
                if result.score >= semantic.score then
                    ranked[#ranked + 1] = candidates[result.index]
                end
            end
        end
        return encode_json({ chronological = recent, semantic = fitting(ranked, semantic.bytes, false) })
    end

    return setmetatable(memory, { __close = memory.close })
end
