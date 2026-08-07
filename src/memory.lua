local json = require("dkjson")

local function encode(value)
    local text, failure = json.encode(value)
    if not text then error(failure) end
    return text
end

local function eventText(slice)
    if slice.type == "request" then return slice.value end
    if slice.type ~= "response" then return nil end
    if slice.source == "zinc" then
        return type(slice.value) == "string" and slice.value or encode(slice.value)
    end
    if slice.source == "tool" then
        local value = type(slice.value) == "table" and slice.value.content or slice.value
        return type(value) == "string" and value or encode(value)
    end
    if slice.source == "provider" and type(slice.value) == "table" and type(slice.value.tool_calls) == "table" and #slice.value.tool_calls > 0 then
        return encode(slice.value.tool_calls)
    end
end

local function source(slice)
    return slice.type == "request" and "request" or slice.source
end

local function document(slice)
    return encode({slice = slice.idx, run = slice.run, source = source(slice), value = slice.value})
end

return function(config, store, provider)
    local function index(events)
        local texts, byId = {}, {}
        for _, slice in ipairs(events) do
            local text = eventText(slice)
            if text then texts[slice.idx], byId[slice.idx] = text, slice end
        end
        local ids = {}
        for idx in pairs(texts) do ids[#ids + 1] = idx end
        table.sort(ids)
        local missing = store:missing(ids)
        local position = 1
        while position <= #missing do
            local batch, bytes = {}, 0
            while position <= #missing do
                local text = texts[missing[position]]
                if #batch > 0 and bytes + #text > config.store_bytes then break end
                batch[#batch + 1], bytes, position = text, bytes + #text, position + 1
            end
            local vectors, failure = provider:embed(batch, false)
            if not vectors then error("Embedding error: " .. failure) end
            local values = {}
            for offset, vector in ipairs(vectors) do
                local idx = missing[position - #batch + offset - 1]
                values[#values + 1] = {idx = idx, actor = byId[idx].actor, vector = vector}
            end
            store:index(values)
        end
        return texts
    end

    local function rerank(query, slices)
        local documents = {}
        for index, slice in ipairs(slices) do documents[index] = document(slice) end
        local ranked, failure = provider:rerank(query, documents)
        if not ranked then error("Rerank error: " .. failure) end
        return ranked
    end

    local api = {}

    function api:select(spec)
        local tail, tailBytes = store:tail(spec.actor, spec.snapshot, config.store_bytes)
        local texts = index(tail)
        local eligible = {}
        for _, slice in ipairs(tail) do if texts[slice.idx] and #document(slice) <= config.context_bytes then eligible[#eligible + 1] = slice end end
        if #eligible == 0 then return {slices = {}, text = "[]"} end

        local average = math.max(1, math.floor(tailBytes / #eligible))
        local fit = math.max(1, math.floor(config.context_bytes / average))
        local dense = math.min(#eligible, fit * 4)
        local recent = math.min(#eligible, fit)
        local first = eligible[1].idx
        local query, bridges, bridgeBytes = spec.request, {}, 0
        local pool, pooled, lastBridge = {}, {}, nil

        for hop = 1, config.hops do
            local vectors, embeddingFailure = provider:embed({query}, true)
            if not vectors then error("Embedding error: " .. embeddingFailure) end
            local ids, seen = {}, {}
            for _, hit in ipairs(store:nearest(vectors[1], spec.actor, first, spec.snapshot, dense)) do
                ids[#ids + 1], seen[hit.idx] = hit.idx, true
            end
            if hop == 1 then
                for index = #eligible, math.max(1, #eligible - recent + 1), -1 do
                    local idx = eligible[index].idx
                    if not seen[idx] then ids[#ids + 1], seen[idx] = idx, true end
                end
            end
            local candidates = store:fetch(ids, spec.actor, spec.snapshot)
            local ranked = rerank(query, candidates)
            local discovered = {}
            for _, result in ipairs(ranked) do
                local slice = candidates[result.index]
                if slice and not pooled[slice.idx] then
                    local item = {slice = slice, hop = hop, via = lastBridge, score = result.score}
                    pool[#pool + 1], discovered[#discovered + 1], pooled[slice.idx] = item, item, true
                end
            end
            if #discovered == 0 then break end
            local added = false
            for _, item in ipairs(discovered) do
                local parts = {}
                for _, slice in ipairs(store:visibleRun(spec.actor, spec.snapshot, item.slice.run, config.store_bytes)) do
                    if eventText(slice) then parts[#parts + 1] = document(slice) end
                end
                local text = table.concat(parts, "\n")
                if bridgeBytes + #text <= config.context_bytes then
                    bridges[#bridges + 1], bridgeBytes = text, bridgeBytes + #text
                    lastBridge, added = item.slice.idx, true
                    break
                end
            end
            if added then query = spec.request .. "\n\nBridge history discovered so far:\n" .. table.concat(bridges, "\n") end
            if not added or hop == config.hops then break end
        end

        if #pool == 0 then return {slices = {}, text = "[]"} end
        local poolSlices = {}
        for index, item in ipairs(pool) do poolSlices[index] = item.slice end
        local final = rerank(query, poolSlices)
        local runs, selected, records = {}, {}, {}

        local function record(value, relation, rank, anchor, provenance)
            local slice = value.slice or value
            local item = provenance or value
            local result = {
                rank = rank,
                hop = item.hop,
                slice = slice.idx,
                run = slice.run,
                actor = slice.actor,
                source = source(slice),
                relation = relation,
                anchor = anchor,
                via = item.via,
                value = slice.value,
            }
            return setmetatable(result, {__jsonorder = {"rank", "hop", "slice", "run", "actor", "source", "relation", "anchor", "via", "value"}})
        end

        local function fits(additions)
            local trial = {table.unpack(records)}
            for _, value in ipairs(additions) do trial[#trial + 1] = value end
            return #encode(trial) <= config.context_bytes
        end

        for rank, result in ipairs(final) do
            local item = pool[result.index]
            if item and not selected[item.slice.idx] then
                local run = runs[item.slice.run]
                if not run then
                    run = store:visibleRun(spec.actor, spec.snapshot, item.slice.run, config.store_bytes)
                    runs[item.slice.run] = run
                end
                local textual = {}
                for _, slice in ipairs(run) do if eventText(slice) then textual[#textual + 1] = slice end end
                local position
                for index, slice in ipairs(textual) do if slice.idx == item.slice.idx then position = index; break end end
                local additions = {}
                if position and position > 1 and not selected[textual[position - 1].idx] then additions[#additions + 1] = record(textual[position - 1], "previous", rank, item.slice.idx, item) end
                additions[#additions + 1] = record(item, "match", rank, nil)
                if position and position < #textual and not selected[textual[position + 1].idx] then additions[#additions + 1] = record(textual[position + 1], "next", rank, item.slice.idx, item) end
                if not fits(additions) then additions = {record(item, "match", rank, nil)} end
                if fits(additions) then
                    for _, value in ipairs(additions) do
                        selected[value.slice] = true
                        records[#records + 1] = value
                    end
                end
            end
        end

        local slices = {}
        for _, value in ipairs(records) do slices[#slices + 1] = value.slice end
        return {slices = slices, text = encode(records)}
    end

    function api:access(actor, snapshot)
        return {
            slice = function(idx)
                idx = assert(math.tointeger(idx), "Slice index must be an integer")
                return store:visibleSlice(actor, snapshot, idx)
            end,
            run = function(run)
                run = assert(math.tointeger(run), "Run index must be an integer")
                return store:visibleRun(actor, snapshot, run, config.store_bytes)
            end,
        }
    end

    return api
end
