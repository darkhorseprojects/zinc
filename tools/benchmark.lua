local json = require("lunajson")
local memory_module = require("zinc.internal.memory")

local model = {}
function model:encode(value) return json.encode(value) end

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

local config = {
    store = ":memory:",
    cygnet = "data/cygnet.db",
    retrieval = { semantic_language = "en", semantic_depth = 1, semantic_attention_cutoff = 0 },
}
local function milliseconds(work)
    local started = os.clock()
    local result = work()
    return (os.clock() - started) * 1000, result
end
local open_ms, memory = milliseconds(function() return memory_module(config, model) end)
local first = memory:begin("benchmark", "portable agent memory")
memory:append("benchmark", first.id, "assistant", "Portable Agents use sealed Lua capabilities.")
local start = memory:begin("benchmark", "inspect portable agent memory")
local samples = {}
for index = 1, 40 do
    samples[index] = milliseconds(
        function()
            return memory:context(
                "benchmark",
                start.id,
                "portable agent memory",
                { retrieval = { semantic_terms = 512, grounding_tokens = 512, exact_forms = 64, candidates = 64 } }
            )
        end
    )
end
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
