local sqlite = require("lsqlite3complete")

local function path(directory, value)
    assert(
        type(value) == "string"
            and value:match("^[%w_./-]+$")
            and not value:match("^[/\\]")
            and not value:find("..", 1, true),
        "Cygnet path is invalid"
    )
    return directory .. package.config:sub(1, 1) .. value:gsub("[/\\]", package.config:sub(1, 1))
end
local function normalize(value)
    return value:lower():gsub("_", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
end
local function slots(count)
    return string.rep("?,", count):sub(1, -2)
end

return function(config, directory)
    local db = assert(sqlite.open(path(directory, config.cygnet), sqlite.OPEN_READONLY))
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
        local output, output_seen = {}, {}
        for _, initial in ipairs(selected) do
            local frontier, visited = initial, {}
            for _, concept in ipairs(frontier) do
                visited[concept] = true
            end
            for depth = 0, request.semantic_depth do
                local query = "SELECT DISTINCT term FROM concept_terms WHERE language=? AND concept IN ("
                    .. slots(#frontier)
                    .. ") ORDER BY term"
                local arguments = { request.semantic_language, table.unpack(frontier) }
                for _, row in ipairs(rows(query, table.unpack(arguments))) do
                    local key = row.term:lower()
                    if not output_seen[key] then
                        output_seen[key], output[#output + 1] = true, row.term
                        if #output == request.maximum_terms then
                            return output
                        end
                    end
                end
                if depth == request.semantic_depth then
                    break
                end
                local following = {}
                local related = "SELECT DISTINCT target FROM concept_edges WHERE source IN ("
                    .. slots(#frontier)
                    .. ") ORDER BY target"
                for _, row in ipairs(rows(related, table.unpack(frontier))) do
                    if not visited[row.target] then
                        visited[row.target], following[#following + 1] = true, row.target
                    end
                end
                if #following == 0 then
                    break
                end
                frontier = following
            end
        end
        return output
    end

    return {
        expand = function(_, request)
            assert(type(request.tokens) == "table" and type(request.exact_forms) == "table", "Cygnet forms are invalid")
            assert(
                type(request.semantic_language) == "string" and request.semantic_language ~= "",
                "Cygnet language is invalid"
            )
            assert(
                request.semantic_depth >= 0 and request.semantic_depth <= 4,
                "Cygnet depth must be from zero to four"
            )
            assert(request.maximum_terms >= 1 and request.maximum_terms <= 4096, "Cygnet term limit is invalid")
            for _, token in ipairs(request.tokens) do
                assert(type(token) == "string" and token ~= "" and not token:find("%s"), "Cygnet token is invalid")
            end
            return expand(select_concepts(request), request)
        end,
        close = function()
            assert(db:close() == sqlite.OK, "closing Cygnet failed")
        end,
    }
end
