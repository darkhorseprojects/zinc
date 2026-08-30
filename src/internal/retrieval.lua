return function(config, store, models, cygnet)
    local function fits(records, maximum)
        return models:tokens(models:encode(records)) <= maximum
    end

    local function chronological(actor, start)
        local result = {}
        for _, value in ipairs(store:before(actor, start, config.max_chronological_window_tokens)) do
            table.insert(result, 1, { id = value.id, role = value.role, text = value.text })
            if not fits(result, config.max_chronological_window_tokens) then
                table.remove(result, 1)
                break
            end
        end
        return result
    end

    local function semantic(actor, start, anchor, recent)
        local grounded =
            store:ground(anchor, config.max_semantic_terms, config.max_grounding_tokens, config.max_exact_forms)
        local terms = grounded.terms
        local remaining = config.max_semantic_terms - #terms
        if remaining > 0 then
            local expanded = cygnet({
                tokens = grounded.tokens,
                exact_forms = grounded.exact_forms,
                semantic_language = config.semantic_language,
                semantic_depth = config.semantic_depth,
                semantic_attention_cutoff = config.semantic_attention_cutoff,
                maximum_terms = remaining,
            })
            for _, term in ipairs(expanded) do
                terms[#terms + 1] = term
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
        local result = {}
        for _, index in ipairs(models:rerank(anchor, passages)) do
            result[#result + 1] = candidates[index]
            if not fits(result, config.max_retrieval_window_tokens) then
                result[#result] = nil
                break
            end
        end
        return result
    end

    return function(actor, start, anchor)
        local recent = chronological(actor, start)
        return models:encode({ chronological = recent, semantic = semantic(actor, start, anchor, recent) })
    end
end
