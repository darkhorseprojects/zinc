local encode = require("lunajson").encode

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function project(record)
    return { id = record.id, role = record.role, text = record.text }
end

return function(config, store, models, cygnet)
    assert(config.semantic_depth >= 0 and config.semantic_depth <= 4, "semantic depth must be from zero to four")

    local function chronological(actor, start)
        local newest, used = {}, 2
        store:before(actor, start, function(value)
            local record = project(value)
            local size = #encode(record) + (#newest > 0 and 1 or 0)
            if used + size > config.max_chronological_window_bytes then
                return false
            end
            used = used + size
            newest[#newest + 1] = record
        end)
        local result = {}
        for index = #newest, 1, -1 do
            result[#result + 1] = newest[index]
        end
        return result
    end

    local function semantic(actor, start, anchor, recent)
        local grounded =
            store:ground(anchor, config.max_semantic_terms, config.max_semantic_input_tokens, config.max_exact_forms)
        local terms, seen = {}, {}
        for _, term in ipairs(grounded.terms) do
            terms[#terms + 1], seen[term] = term, true
        end
        local remaining = config.max_semantic_terms - #terms
        if remaining > 0 then
            local expanded = cygnet:expand({
                tokens = grounded.tokens,
                exact_forms = grounded.exact_forms,
                semantic_language = config.semantic_language,
                semantic_depth = config.semantic_depth,
                semantic_attention_cutoff = config.semantic_attention_cutoff,
                maximum_terms = remaining,
            })
            for _, term in ipairs(expanded) do
                if not seen[term] then
                    terms[#terms + 1], seen[term] = term, true
                end
            end
        end
        local excluded, candidates = {}, {}
        for _, record in ipairs(recent) do
            excluded[record.id] = true
        end
        for _, record in ipairs(store:search(actor, start, terms, config.max_retrieval_candidates)) do
            if not excluded[record.id] then
                excluded[record.id] = true
                candidates[#candidates + 1] = project(record)
            end
        end
        local passages = {}
        for index, record in ipairs(candidates) do
            passages[index] = record.role .. ":\n" .. record.text
        end
        local ranking, count = models:rerank(anchor, passages)
        assert(#ranking == count and count <= #candidates, "reranker selected count is invalid")
        local ordered, ranked = {}, {}
        for _, item in ipairs(ranking) do
            local index = math.tointeger(item.index)
            assert(index and index <= count and not ranked[index] and finite(item.score), "reranker item is invalid")
            ranked[index] = true
            ordered[#ordered + 1] = { record = candidates[index], score = item.score }
        end
        table.sort(ordered, function(left, right)
            return left.score == right.score and left.record.id < right.record.id or left.score > right.score
        end)
        local result, used = {}, 2
        for _, item in ipairs(ordered) do
            local size = #encode(item.record) + (#result > 0 and 1 or 0)
            if used + size > config.max_retrieval_window_bytes then
                break
            end
            used = used + size
            result[#result + 1] = item.record
        end
        return result
    end

    local api = {}
    function api:start(actor, start, anchor)
        local recent = chronological(actor, start)
        return {
            actor = actor,
            start = start,
            anchor = anchor,
            chronological = recent,
            semantic = semantic(actor, start, anchor, recent),
        }
    end
    function api:context(state)
        return encode({ chronological = state.chronological, semantic = state.semantic })
    end
    function api:results(actor, start, ask)
        return {
            read = function(id)
                return store:read(actor, start, id)
            end,
            around = function(id)
                return store:around(actor, start, id)
            end,
            ask = ask,
        }
    end
    return api
end
