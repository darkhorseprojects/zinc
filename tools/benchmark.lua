local json = require("dkjson")
local uv = require("luv")
local Cygnet = require("src.cygnet")
local Models = require("src.models")
local SSE = require("src.sse")

local cygnet_samples = {}
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
    cygnet_samples[index] = (uv.hrtime() - started) / 1e6
end
cygnet:close()
table.sort(cygnet_samples)

local template = (os.getenv("TMPDIR") or "/tmp") .. "/zinc-benchmark-XXXXXX"
local fd, port_file = assert(uv.fs_mkstemp(template))
assert(uv.fs_close(fd))
assert(uv.fs_unlink(port_file))
local server_exited = false
local server = assert(uv.spawn(assert(uv.exepath()), {
    args = { "tests/http_fixture.lua", port_file },
    cwd = assert(uv.cwd()),
    stdio = { nil, nil, nil },
}, function()
    server_exited = true
end))
local port
for _ = 1, 200 do
    local file = io.open(port_file, "rb")
    if file then
        port = assert(tonumber(assert(file:read("*a"))))
        assert(file:close())
        break
    end
    uv.sleep(5)
end
assert(port, "HTTP fixture did not start")
local models = Models.new({
    chat = { endpoint = "http://127.0.0.1:" .. port .. "/chat", model = "chat" },
    rerank = { endpoint = "http://127.0.0.1:" .. port .. "/rerank", model = "rerank" },
    max_model_request_bytes = 1048576,
}, SSE)
local chat_samples = {}
for index = 1, 40 do
    local started = uv.hrtime()
    local stream = assert(models:chat({ { role = "user", content = "benchmark" } }))
    local first, failure = stream()
    chat_samples[index] = (uv.hrtime() - started) / 1e6
    assert(first and first.type == "reasoning", failure or "chat produced no first event")
    while stream() do
    end
end
table.sort(chat_samples)
server:kill("sigterm")
while not server_exited do
    uv.run("once")
end
server:close()
uv.fs_unlink(port_file)

print(assert(json.encode({
    cygnet_open_ms = open_ms,
    representative_expansion = {
        samples = #cygnet_samples,
        minimum_ms = cygnet_samples[1],
        median_ms = cygnet_samples[20],
        p95_ms = cygnet_samples[38],
        maximum_ms = cygnet_samples[#cygnet_samples],
    },
    first_chat_event = {
        samples = #chat_samples,
        minimum_ms = chat_samples[1],
        median_ms = chat_samples[20],
        p95_ms = chat_samples[38],
        maximum_ms = chat_samples[#chat_samples],
    },
})))
assert(open_ms <= 4, "Cygnet open exceeds 4 ms")
assert(cygnet_samples[20] <= 4, "Cygnet median exceeds 4 ms")
assert(cygnet_samples[38] <= 6, "Cygnet p95 exceeds 6 ms")
assert(chat_samples[20] < 10, "first chat event median is not below 10 ms")
