local json = require("dkjson")
local uv = require("luv")
local Cygnet = require("src.cygnet")

local samples = {}
local opened = uv.hrtime()
local cygnet = Cygnet.open({
    source = "data/cygnet.db",
    index = "data/cygnet-index.db",
    source_identity = "aae2cdb1418c1435558584a91181e1cb94459f2506c16f2be4b00e81428deaff",
})
local open_ms = (uv.hrtime() - opened) / 1e6
for index = 1, 40 do
    local started = uv.hrtime()
    cygnet:expand({
        tokens = { "portable", "agent", "memory" },
        exact_forms = {},
        semantic_language = "en",
        semantic_depth = 1,
        semantic_attention_cutoff = 0,
        maximum_terms = 512,
    })
    samples[index] = (uv.hrtime() - started) / 1e6
end
cygnet:close()
table.sort(samples)
print(assert(json.encode({
    cygnet_open_ms = open_ms,
    representative = {
        samples = #samples,
        minimum_ms = samples[1],
        median_ms = samples[20],
        p95_ms = samples[38],
        maximum_ms = samples[#samples],
    },
})))
assert(open_ms <= 4, "Cygnet open exceeds 4 ms")
assert(samples[20] <= 4, "Cygnet median exceeds 4 ms")
assert(samples[38] <= 6, "Cygnet p95 exceeds 6 ms")
