return function(config, store, models, cygnet)
    local function fits(records, maximum)
        return models:tokens(models:encode(records)) <= maximum
    end

    local function chronological(actor, start)
        local result, cursor = {}, start
        while true do
            local page = store:before(actor, cursor, 32)
            if #page == 0 then
                break
            end
            for _, value in ipairs(page) do
                table.insert(result, 1, { id = value.id, role = value.role, text = value.text })
                if not fits(result, config.max_chronological_window_tokens) then
                    table.remove(result, 1)
                    page = {}
                    break
                end
                cursor = value.id
            end
            if #page < 32 then
                break
            end
        end
        return result
    end

    local function semantic(actor, start, anchor, recent)
        local grounded =
            store:ground(anchor, config.max_semantic_terms, config.max_grounding_tokens, config.max_exact_forms)
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
                candidates[#candidates + 1] = { id = record.id, role = record.role, text = record.text }
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
            assert(
                index
                    and index <= count
                    and not ranked[index]
                    and type(item.score) == "number"
                    and item.score == item.score
                    and math.abs(item.score) < math.huge,
                "reranker item is invalid"
            )
            ranked[index] = true
            ordered[#ordered + 1] = { record = candidates[index], score = item.score }
        end
        table.sort(ordered, function(left, right)
            return left.score == right.score and left.record.id < right.record.id or left.score > right.score
        end)
        local result = {}
        for _, item in ipairs(ordered) do
            result[#result + 1] = item.record
            if not fits(result, config.max_retrieval_window_tokens) then
                result[#result] = nil
                break
            end
        end
        return result
    end

    local api = {}
    function api:start(actor, start, anchor)
        local recent = chronological(actor, start)
        return models:encode({ chronological = recent, semantic = semantic(actor, start, anchor, recent) })
    end
    return api
end
