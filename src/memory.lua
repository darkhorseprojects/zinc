local function document(slice)
    local parts = {}
    if not slice or type(slice) ~= "table" or not slice.events then return "" end
    for _, event in ipairs(slice.events) do
        local value = event.value
        if event.source == "user" then
            parts[#parts + 1] = "User: " .. (type(value) == "string" and value or tostring(value or ""))
        elseif event.source == "tool" then
            parts[#parts + 1] = "Tool: " .. (type(value) == "table" and value.content or tostring(value or ""))
        elseif event.source == "provider" then
            if type(value) == "table" and value.content then
                parts[#parts + 1] = "Assistant: " .. tostring(value.content)
            end
        end
    end
    return table.concat(parts, "\n")
end

local function eventText(slice)
    local doc = document(slice)
    return doc ~= "" and doc or nil
end

local function truncate(str, maxChars)
    if not str or #str <= (maxChars or 1500) then return str end
    return str:sub(1, maxChars or 1500)
end

return function(config, store, provider)
    local function index(events)
        local texts, byId = {}, {}
        for _, slice in ipairs(events) do
            local text = eventText(slice)
            if text then
                texts[slice.idx], byId[slice.idx] = truncate(text, 1500), slice
            end
        end
        local ids = {}
        for idx in pairs(texts) do ids[#ids + 1] = idx end
        table.sort(ids)
        local missing = store:missing(ids)
        local position = 1
        while position <= #missing do
            local batch, batchIds, bytes = {}, {}, 0
            while position <= #missing do
                local idx = missing[position]
                local text = texts[idx]
                if #batch > 0 and bytes + #text > config.store_bytes then break end
                batch[#batch + 1] = text
                batchIds[#batchIds + 1] = idx
                bytes = bytes + #text
                position = position + 1
            end
            local vectors, failure = provider:embed(batch, false)
            if vectors then
                local values = {}
                for offset, vector in ipairs(vectors) do
                    local idx = batchIds[offset]
                    values[#values + 1] = {idx = idx, actor = byId[idx].actor, vector = vector}
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
        for index, slice in ipairs(slices) do
            documents[index] = truncate(document(slice), 1500)
        end
        local ranked, failure = provider:rerank(truncate(query, 1500), documents)
        if not ranked then
            io.stderr:write("Warning: rerank failed: " .. tostring(failure) .. "\n")
            local fallback = {}
            for i = 1, #slices do
                fallback[i] = {index = i, score = 1.0 - (i * 0.01)}
            end
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
                eligible[#eligible + 1] = slice
            end
        end
        if #eligible == 0 then return {slices = {}, text = "[]"} end

        local average = math.max(1, math.floor(tailBytes / #eligible))
        local fit = math.max(1, math.floor(config.context_bytes / average))
        local dense = math.min(#eligible, fit * 4)
        local recent = math.min(#eligible, fit)
        local first = eligible[1].idx
        local query, bridges, bridgeBytes = spec.request, {}, 0
        local pool, pooled, lastBridge = {}, {}, nil

        for hop = 1, config.hops do
            local vectors, embeddingFailure = provider:embed({truncate(query, 1500)}, true)
            if not vectors then
                io.stderr:write("Warning: query embedding failed: " .. tostring(embeddingFailure) .. "\n")
                break
            end
            local poolVector = vectors[1]
            local matches = store:nearest(poolVector, spec.actor, first, spec.snapshot, dense)
            for _, match in ipairs(matches) do
                local slice = store:slice(match.idx)
                if slice and not pooled[slice.idx] and #document(slice) <= config.context_bytes then
                    pool[#pool + 1] = slice
                    pooled[slice.idx] = true
                end
            end
            if #pool == 0 then break end

            local ranked = rerank(query, pool)
            local bestIdx = ranked[1] and ranked[1].index
            local bestSlice = bestIdx and pool[bestIdx]
            if not bestSlice or bestSlice.idx == lastBridge then break end

            local doc = document(bestSlice)
            if bridgeBytes + #doc > config.context_bytes then break end
            bridges[#bridges + 1] = bestSlice
            bridgeBytes = bridgeBytes + #doc
            lastBridge = bestSlice.idx
            query = doc
        end

        local combined, combinedSet = {}, {}
        for _, slice in ipairs(bridges) do
            if not combinedSet[slice.idx] then
                combined[#combined + 1] = slice
                combinedSet[slice.idx] = true
            end
        end
        for i = 1, recent do
            local slice = eligible[i]
            if slice and not combinedSet[slice.idx] then
                combined[#combined + 1] = slice
                combinedSet[slice.idx] = true
            end
        end

        local rankedCombined = rerank(spec.request, combined)
        local finalSlices, currentBytes = {}, 0
        for _, item in ipairs(rankedCombined) do
            local slice = combined[item.index]
            local doc = document(slice)
            if currentBytes + #doc <= config.context_bytes then
                finalSlices[#finalSlices + 1] = slice
                currentBytes = currentBytes + #doc
            end
        end

        table.sort(finalSlices, function(a, b) return a.idx < b.idx end)

        local formatted = {}
        for _, slice in ipairs(finalSlices) do
            formatted[#formatted + 1] = {
                slice = slice.idx,
                content = document(slice),
            }
        end

        local dkjson = require("dkjson")
        return {
            slices = finalSlices,
            text = dkjson.encode(formatted),
        }
    end

    function api:access(actor, snapshot)
        return {
            slice = function(index)
                return store:visibleSlice(actor, snapshot, index)
            end,
            run = function(runId)
                return store:visibleRun(actor, snapshot, runId, config.store_bytes)
            end,
        }
    end

    return api
end
