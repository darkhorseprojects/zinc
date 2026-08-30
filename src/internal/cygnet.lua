local sqlite = require("lsqlite3complete")

local function normalize(value)
    return value:lower():gsub("_", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
end
return function(path)
    assert(type(path) == "string" and path ~= "", "Cygnet path is invalid")
    local db = assert(sqlite.open(path, sqlite.OPEN_READONLY))
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
    local metadata = {}
    for _, row in ipairs(rows("SELECT key,value FROM metadata")) do
        metadata[row.key] = row.value
    end
    assert(
        metadata.format_version == "2" and metadata.algorithm == "relation-balanced-pagerank-v1",
        "Cygnet format is unsupported"
    )
    local maximum = assert(tonumber(metadata.maximum_form_tokens), "Cygnet metadata is incomplete")
    local languages = {}
    for _, row in ipairs(rows("SELECT language,normalization,vocabulary FROM languages")) do
        languages[row.language] = row
    end

    local function concepts(form, request)
        local score, language =
            rows("SELECT probability FROM form_scores WHERE language=? AND form=?", request.semantic_language, form)[1],
            languages[request.semantic_language]
        if
            not score
            or not language
            or -math.log(score.probability / language.normalization * language.vocabulary)
                < request.semantic_attention_cutoff
        then
            return
        end
        local result = {}
        for _, row in
            ipairs(
                rows(
                    "SELECT concept FROM form_concepts WHERE language=? AND form=? ORDER BY concept",
                    request.semantic_language,
                    form
                )
            )
        do
            result[#result + 1] = row.concept
        end
        return #result > 0 and result or nil
    end

    local function select_concepts(request)
        local selected, seen, offset = {}, {}, 1
        local function add(values)
            if not values then
                return false
            end
            local key = table.concat(values, ",")
            if not seen[key] then
                seen[key], selected[#selected + 1] = true, values
            end
            return true
        end
        while offset <= #request.tokens do
            local accepted = 0
            for count = math.min(maximum, #request.tokens - offset + 1), 1, -1 do
                if add(concepts(normalize(table.concat(request.tokens, " ", offset, offset + count - 1)), request)) then
                    accepted = count
                    break
                end
            end
            offset = offset + math.max(accepted, 1)
        end
        for _, form in ipairs(request.exact_forms) do
            add(concepts(normalize(form), request))
        end
        return selected
    end

    local function expand(selected, request)
        local output, seen = {}, {}
        for _, initial in ipairs(selected) do
            local seeds, arguments = {}, {}
            for index, concept in ipairs(initial) do
                seeds[index], arguments[index] = index == 1 and "SELECT ?,0" or "UNION SELECT ?,0", concept
            end
            arguments[#arguments + 1] = request.semantic_depth
            arguments[#arguments + 1] = request.semantic_language
            local query = "WITH RECURSIVE reachable(concept,depth) AS ("
                .. table.concat(seeds, " ")
                .. " UNION SELECT e.target,r.depth+1 FROM concept_edges e JOIN reachable r ON e.source=r.concept WHERE r.depth<?) "
                .. "SELECT t.term,min(r.depth) depth FROM reachable r JOIN concept_terms t ON t.concept=r.concept WHERE t.language=? GROUP BY t.term ORDER BY depth,t.term"
            for _, row in ipairs(rows(query, table.unpack(arguments))) do
                local key = row.term:lower()
                if not seen[key] then
                    seen[key], output[#output + 1] = true, row.term
                    if #output == request.maximum_terms then
                        return output
                    end
                end
            end
        end
        return output
    end

    return {
        expand = function(_, request)
            return expand(select_concepts(request), request)
        end,
    }
end
