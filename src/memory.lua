local function document(slice)
    if not slice or type(slice) ~= "table" then return "" end
    if slice.events and type(slice.events) == "table" then
        local parts = {}
        for _, event in ipairs(slice.events) do
            local val = event.value
            if event.source == "user" or event.type == "request" then
                parts[#parts + 1] = "User: " .. (type(val) == "string" and val or tostring(val or ""))
            elseif event.source == "tool" then
                parts[#parts + 1] = "Tool: " .. (type(val) == "table" and val.content or tostring(val or ""))
            elseif event.source == "zinc" or event.source == "provider" then
                parts[#parts + 1] = "Assistant: " .. (type(val) == "table" and (val.content or "") or tostring(val or ""))
            end
        end
        return table.concat(parts, "\n")
    end
    if slice.type == "request" then
        return type(slice.value) == "string" and slice.value or tostring(slice.value or "")
    elseif slice.type == "response" then
        local val = slice.value
        if slice.source == "tool" then
            return type(val) == "table" and (val.content or "") or tostring(val or "")
        elseif slice.source == "zinc" or slice.source == "provider" then
            return type(val) == "table" and (val.content or "") or tostring(val or "")
        end
        return type(val) == "string" and val or tostring(val or "")
    elseif slice.type == "merged" then
        local parts = {}
        for _, ev in ipairs(slice.events or {}) do
            local doc = document(ev)
            if doc ~= "" then parts[#parts + 1] = doc end
        end
        return table.concat(parts, "\n")
    end
    return ""
end

local function truncate(str, maxChars)
    if not str or #str <= (maxChars or 1500) then return str end
    return str:sub(1, maxChars or 1500)
end

return function(config, store, provider)
    local function index(events)
        local texts, byId = {}, {}
        for _, slice in ipairs(events) do
            local text = document(slice)
            if text ~= "" then texts[slice.idx], byId[slice.idx] = truncate(text, 1500), slice end
        end
        local ids = {}
        for idx in pairs(texts) do ids[#ids + 1] = idx end
        table.sort(ids)
        local missing, position = store:missing(ids), 1
        while position <= #missing do
            local batch, batchIds, bytes = {}, {}, 0
            while position <= #missing do
                local idx = missing[position]
                local text = texts[idx]
                if #batch > 0 and bytes + #text > config.store_bytes then break end
                batch[#batch + 1], batchIds[#batchIds + 1], bytes, position = text, idx, bytes + #text, position + 1
            end
            local vectors, failure = provider:embed(batch, false)
            if vectors then
                local values = {}
                for offset, vector in ipairs(vectors) do
                    values[#values + 1] = {idx = batchIds[offset], actor = byId[batchIds[offset]].actor, vector = vector}
                end
                store:index(values)
            else
                io.stderr:write("Warning: embedding batch failed: " .. tostring(failure) .. "\n")
            end
        end
        return texts
    end

    local function rerank(query, slices)
        local documents = {}
        for index, slice in ipairs(slices) do documents[index] = truncate(document(slice), 1500) end
        local ranked, failure = provider:rerank(truncate(query, 1500), documents)
        if not ranked then
            io.stderr:write("Warning: rerank failed: " .. tostring(failure) .. "\n")
            local fallback = {}
            for i = 1, #slices do fallback[i] = {index = i, score = 1.0 - (i * 0.01)} end
            return fallback
        end
        return ranked
    end

    local api = {}

    function api:select(spec)
        local tail, tailBytes = store:tail(spec.actor, spec.snapshot, config.store_bytes)
        local texts = index(tail)
        local eligible = {}
        for _, slice in ipairs(tail) do
            if texts[slice.idx] and #document(slice) <= config.context_bytes then
                slice.hop = 1
                eligible[#eligible + 1] = slice
            end
        end
        if #eligible == 0 then return {slices = {}, text = "[]"} end

        local average = math.max(1, math.floor(tailBytes / #eligible))
        local fit = math.max(1, math.floor(config.context_bytes / average))
        local dense, recent, first = math.min(#eligible, fit * 4), math.min(#eligible, fit), tail[1].idx
        local query, bridges, bridgeBytes = spec.request, {}, 0
        local pool, pooled, lastBridge = {}, {}, nil

        for hop = 1, config.hops do
            local vectors, embeddingFailure = provider:embed({truncate(query, 1500)}, true)
            if not vectors then
                io.stderr:write("Warning: query embedding failed: " .. tostring(embeddingFailure) .. "\n")
                break
            end
            local matches = store:nearest(vectors[1], spec.actor, first, spec.snapshot, dense)
            for _, match in ipairs(matches) do
                local slice = store:slice(match.idx)
                if slice and not pooled[slice.idx] and #document(slice) <= config.context_bytes then
                    slice.hop = hop
                    pool[#pool + 1], pooled[slice.idx] = slice, true
                end
            end
            if #pool == 0 then break end

            local ranked = rerank(query, pool)
            local bestIdx = ranked[1] and ranked[1].index
            local bestSlice = bestIdx and pool[bestIdx]
            if not bestSlice or bestSlice.idx == lastBridge then break end

            local doc = document(bestSlice)
            if bridgeBytes + #doc > config.context_bytes then break end
            bestSlice.hop = hop
            bridges[#bridges + 1] = bestSlice
            bridgeBytes = bridgeBytes + #doc
            lastBridge = bestSlice.idx
            query = "Bridge history:\n" .. doc
        end

        local combined, combinedSet = {}, {}
        for _, slice in ipairs(bridges) do
            if not combinedSet[slice.idx] then combined[#combined + 1], combinedSet[slice.idx] = slice, true end
        end
        for i = #eligible, math.max(1, #eligible - recent + 1), -1 do
            local slice = eligible[i]
            if slice and not combinedSet[slice.idx] then combined[#combined + 1], combinedSet[slice.idx] = slice, true end
        end

        local rankedCombined = rerank(spec.request, combined)
        local finalSlices, currentBytes, selected = {}, 0, {}

        -- Preserve multi-hop bridge chain
        for _, slice in ipairs(bridges) do
            local doc = document(slice)
            local overhead = #doc + 100
            if currentBytes + overhead <= config.context_bytes then
                finalSlices[#finalSlices + 1], currentBytes, selected[slice.idx] = slice, currentBytes + overhead, true
            end
        end

        -- Fill remaining budget with top-ranked candidates
        for _, item in ipairs(rankedCombined) do
            local slice = combined[item.index]
            if not selected[slice.idx] then
                local doc = document(slice)
                local overhead = #doc + 100
                if currentBytes + overhead <= config.context_bytes then
                    finalSlices[#finalSlices + 1], currentBytes, selected[slice.idx] = slice, currentBytes + overhead, true
                end
            end
        end

        table.sort(finalSlices, function(a, b) return a.idx < b.idx end)

        local sliceIds, formatted = {}, {}
        for rank, slice in ipairs(finalSlices) do
            sliceIds[#sliceIds + 1] = slice.run or slice.idx
            formatted[#formatted + 1] = {
                rank = rank,
                hop = slice.hop or 1,
                slice = slice.idx,
                run = slice.run,
                actor = slice.actor,
                source = slice.source or (slice.type == "request" and "user" or "zinc"),
                relation = (slice.source == "user" or slice.type == "request") and "previous" or "next",
                value = slice.value or document(slice),
            }
        end

        local dkjson = require("dkjson")
        return {slices = sliceIds, text = dkjson.encode(formatted)}
    end

    function api:access(actor, snapshot)
        return {
            slice = function(index) return store:visibleSlice(actor, snapshot, index) end,
            run = function(runId) return store:visibleRun(actor, snapshot, runId, config.store_bytes) end,
        }
    end

    return api
end
