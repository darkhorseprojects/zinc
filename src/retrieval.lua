local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function passage(record)
    return record.role .. ":\n" .. record.text
end

local function project(record)
    return { id = record.id, role = record.role, text = record.text }
end

local module = {}

function module.new(store, models, options)
    options = options or {}
    local encode = assert(models.encode, "model JSON encoder is required")
    local language = assert(
        type(options.semantic_language) == "string" and options.semantic_language ~= "" and options.semantic_language,
        "semantic language is required"
    )
    local depth = assert(math.tointeger(options.semantic_depth), "semantic depth must be an integer")
    local attention_cutoff = assert(options.semantic_attention_cutoff, "semantic attention cutoff is required")
    assert(finite(attention_cutoff), "semantic attention cutoff must be finite")
    local chronological_maximum =
        assert(math.tointeger(options.max_chronological_window_bytes), "chronological window must be an integer")
    local semantic_maximum =
        assert(math.tointeger(options.max_retrieval_window_bytes), "retrieval window must be an integer")
    local proposal_maximum =
        assert(math.tointeger(options.max_proposal_terms), "proposal term limit must be an integer")
    local candidate_maximum =
        assert(math.tointeger(options.max_retrieval_candidates), "retrieval candidate limit must be an integer")
    assert(depth >= 0 and depth <= 4, "semantic depth must be from zero to four")
    assert(chronological_maximum > 0 and semantic_maximum > 0, "context windows must be positive")
    assert(proposal_maximum > 0, "proposal term limit must be positive")
    assert(candidate_maximum > 0, "retrieval candidate limit must be positive")

    local function pack(values, maximum, get)
        local selected, used = {}, 2
        for _, value in ipairs(values) do
            local record = project(get and get(value) or value)
            local encoded = encode(record)
            local addition = #encoded + (#selected > 0 and 1 or 0)
            if used + addition > maximum then
                break
            end
            used = used + addition
            selected[#selected + 1] = record
        end
        return selected
    end

    local function chronological(actor, start)
        local newest, used = {}, 2
        store:before(actor, start, function(value)
            local record = project(value)
            local encoded = encode(record)
            local addition = #encoded + (#newest > 0 and 1 or 0)
            if used + addition > chronological_maximum then
                return false
            end
            used = used + addition
            newest[#newest + 1] = record
        end)
        local result = {}
        for index = #newest, 1, -1 do
            result[#result + 1] = newest[index]
        end
        return result
    end

    local function semantic(actor, start, anchor, recent)
        local grounded = store:ground(anchor, proposal_maximum)
        local terms, seen = {}, {}
        for _, term in ipairs(grounded.terms) do
            terms[#terms + 1] = term
            seen[term] = true
        end
        local remaining = proposal_maximum - #terms
        if remaining > 0 then
            local proposed, proposal_failure = models:propose({
                tokens = grounded.tokens,
                exact_forms = grounded.exact_forms,
                semantic_language = language,
                semantic_depth = depth,
                semantic_attention_cutoff = attention_cutoff,
                maximum_terms = remaining,
            })
            assert(proposed, proposal_failure)
            for _, term in ipairs(proposed) do
                if not seen[term] then
                    seen[term] = true
                    terms[#terms + 1] = term
                end
            end
        end
        local excluded = {}
        for _, record in ipairs(recent) do
            excluded[record.id] = true
        end
        local candidates = {}
        for _, record in ipairs(store:search(actor, start, terms, candidate_maximum)) do
            if not excluded[record.id] then
                excluded[record.id] = true
                candidates[#candidates + 1] = project(record)
            end
        end
        if #candidates == 0 then
            return {}
        end
        local passages = {}
        for index, record in ipairs(candidates) do
            passages[index] = passage(record)
        end
        local ranking, reranked_count = models:rerank(anchor, passages)
        assert(ranking, reranked_count)
        assert(
            math.tointeger(reranked_count) and reranked_count >= 0 and reranked_count <= #candidates,
            "reranker selected count is invalid"
        )
        assert(#ranking == reranked_count, "reranker returned the wrong count")
        local ordered, seen = {}, {}
        for _, item in ipairs(ranking) do
            local index = math.tointeger(item.index)
            assert(
                index and index <= reranked_count and candidates[index] and not seen[index] and finite(item.score),
                "reranker item is invalid"
            )
            seen[index] = true
            ordered[#ordered + 1] = { record = candidates[index], score = item.score }
        end
        table.sort(ordered, function(left, right)
            return left.score == right.score and left.record.id < right.record.id or left.score > right.score
        end)
        return pack(ordered, semantic_maximum, function(item)
            return item.record
        end)
    end

    local api = {}

    function api:start(actor, start, anchor)
        assert(type(actor) == "string" and actor ~= "", "retrieval actor must be nonempty text")
        assert(math.tointeger(start), "retrieval start must be an integer")
        assert(type(anchor) == "string" and anchor ~= "", "retrieval anchor must be nonempty text")
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
        assert(type(state) == "table", "retrieval state is invalid")
        return encode({ chronological = state.chronological, semantic = state.semantic })
    end

    return api
end

return module
