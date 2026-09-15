local json = require("lunajson")
local make_memory = assert(loadfile("package/src/memory.lua"))()
local make_store = assert(loadfile("package/src/store.lua"))()

local model = {}
function model:tokens(value)
    local count = 0
    for _ in value:gmatch("%S+") do
        count = count + 1
    end
    return count
end

function model:rerank(_, passages)
    local result = {}
    for index in ipairs(passages) do
        result[index] = index
    end
    return result
end

local function milliseconds(work)
    local started = os.clock()
    local result = work()
    return (os.clock() - started) * 1000, result
end

local open_ms, opened = milliseconds(function()
    local store = make_store({ path = ":memory:" })
    local memory = make_memory({
        cygnet = "data/cygnet.db",
        semantic_language = "en",
        semantic_depth = 1,
        semantic_attention_cutoff = 0,
        chronological_records = 64,
        chronological_tokens = 16384,
        semantic_terms = 512,
        grounding_tokens = 512,
        exact_forms = 64,
        candidates = 64,
        semantic_tokens = 16384,
    }, store, model)
    return { store = store, memory = memory }
end)
local store, memory = opened.store, opened.memory
local first = store:append("benchmark", nil, 0, { { role = "user", text = "portable agent memory" } }, 4096)[1]
local answer = store:append("benchmark", first.id, first.id, {
    { role = "assistant", text = "Portable Agents use explicit Lua capabilities." },
}, 4096)[1]
local samples = {}
for index = 1, 40 do
    samples[index] = milliseconds(function()
        return memory:context("benchmark", answer.id, "portable agent memory")
    end)
end
memory:close()
store:close()
table.sort(samples)
print(json.encode({
    memory_open_ms = open_ms,
    representative_retrieval = {
        samples = #samples,
        minimum_ms = samples[1],
        median_ms = samples[20],
        p95_ms = samples[38],
        maximum_ms = samples[#samples],
    },
}))
assert(open_ms <= 20, "memory open exceeds 20 ms")
assert(samples[20] <= 10, "retrieval median exceeds 10 ms")
assert(samples[38] <= 20, "retrieval p95 exceeds 20 ms")
