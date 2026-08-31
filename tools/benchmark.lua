local json = require("lunajson")
local Cygnet = require("zinc.internal.cygnet")

local function milliseconds(work)
    local started = os.clock()
    local result = work()
    return (os.clock() - started) * 1000, result
end

local open_ms, cygnet = milliseconds(function() return Cygnet("data/cygnet.db") end)
local samples = {}
for index = 1, 40 do
    samples[index] = milliseconds(
        function()
            return cygnet({
                tokens = { "portable", "agent", "memory" },
                exact_forms = {},
                semantic_language = "en",
                semantic_depth = 1,
                semantic_attention_cutoff = 0,
                maximum_terms = 512,
            })
        end
    )
end
table.sort(samples)

print(json.encode({
    cygnet_open_ms = open_ms,
    representative_expansion = {
        samples = #samples,
        minimum_ms = samples[1],
        median_ms = samples[20],
        p95_ms = samples[38],
        maximum_ms = samples[#samples],
    },
}))
assert(open_ms <= 4, "Cygnet open exceeds 4 ms")
assert(samples[20] <= 4, "Cygnet median exceeds 4 ms")
assert(samples[38] <= 6, "Cygnet p95 exceeds 6 ms")
