local sqlite = require("lsqlite3complete")
local EXPAND = [[
WITH RECURSIVE reachable(concept,depth) AS (
 SELECT concept,0 FROM form_concepts WHERE language=? AND form=?
 UNION SELECT e.target,r.depth+1 FROM reachable r JOIN concept_edges e ON e.source=r.concept WHERE r.depth<?
)
SELECT t.term,min(r.depth) depth FROM reachable r JOIN concept_terms t ON t.concept=r.concept
WHERE t.language=? GROUP BY t.term ORDER BY depth,t.term
]]

return function(path)
    assert(type(path) == "string" and path ~= "", "Cygnet path is invalid")
    local db = assert(sqlite.open(path, sqlite.OPEN_READONLY))
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
    local metadata = rows([[
SELECT value maximum FROM metadata WHERE key='maximum_form_tokens'
AND EXISTS(SELECT 1 FROM metadata WHERE key='format_version' AND value='2')
AND EXISTS(SELECT 1 FROM metadata WHERE key='algorithm' AND value='relation-balanced-pagerank-v1')
]])[1]
    local maximum = assert(metadata and tonumber(metadata.maximum), "Cygnet format is unsupported")

    local function recognized(form, request)
        local score = rows(
            [[
SELECT s.probability,l.normalization,l.vocabulary FROM form_scores s JOIN languages l ON l.language=s.language
WHERE s.language=? AND s.form=? AND EXISTS(SELECT 1 FROM form_concepts c WHERE c.language=s.language AND c.form=s.form)
]],
            request.semantic_language,
            form
        )[1]
        return score
            and -math.log(score.probability / score.normalization * score.vocabulary)
                >= request.semantic_attention_cutoff
    end

    local function select_forms(request)
        local selected, seen, offset = {}, {}, 1
        local function add(value)
            local form = value:lower():gsub("_", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
            if not recognized(form, request) then
                return false
            end
            if not seen[form] then
                seen[form], selected[#selected + 1] = true, form
            end
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
        for _, form in ipairs(request.exact_forms) do
            add(form)
        end
        return selected
    end

    return function(request)
        local output, seen = {}, {}
        for _, form in ipairs(select_forms(request)) do
            for _, row in
                ipairs(rows(EXPAND, request.semantic_language, form, request.semantic_depth, request.semantic_language))
            do
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
end
