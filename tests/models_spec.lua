local uv = require("luv")
local Models = require("src.models")
local SSE = require("src.sse")

local processes, paths = {}, {}

local function fixture()
    local template = (os.getenv("TMPDIR") or "/tmp") .. "/zinc-http-XXXXXX"
    local fd, port_file = assert(uv.fs_mkstemp(template))
    assert(uv.fs_close(fd))
    assert(uv.fs_unlink(port_file))
    paths[#paths + 1] = port_file
    local exited = false
    local handle, pid = uv.spawn(assert(uv.exepath()), {
        args = { "tests/http_fixture.lua", port_file },
        cwd = assert(uv.cwd()),
        stdio = { nil, nil, nil },
    }, function()
        exited = true
    end)
    assert(handle, pid)
    processes[#processes + 1] = {
        handle = handle,
        exited = function()
            return exited
        end,
    }
    for _ = 1, 200 do
        local file = io.open(port_file, "rb")
        if file then
            local port = assert(tonumber(assert(file:read("*a"))))
            assert(file:close())
            return "http://127.0.0.1:" .. port
        end
        uv.sleep(5)
    end
    error("HTTP fixture did not start")
end

after_each(function()
    for _, process in ipairs(processes) do
        if not process.exited() then
            process.handle:kill("sigterm")
        end
        while not process.exited() do
            uv.run("once")
        end
        process.handle:close()
    end
    processes = {}
    for _, path in ipairs(paths) do
        uv.fs_unlink(path)
    end
    paths = {}
end)

describe("Models", function()
    it("streams chat events and validates reranker results", function()
        local base = fixture()
        local metrics = {}
        local models = Models.new({
            chat = { endpoint = base .. "/chat", model = "chat" },
            rerank = { endpoint = base .. "/rerank", model = "reranker" },
            max_model_request_bytes = 10000,
            metrics = metrics,
        }, SSE)
        local stream = assert(models:chat({ { role = "user", content = "question" } }))
        local events = {}
        while true do
            local event, failure = stream()
            assert.is_nil(failure)
            if not event then
                break
            end
            events[#events + 1] = event
        end
        assert.same({
            { type = "reasoning", text = "think" },
            { type = "response", text = "answer" },
            { type = "finish", reason = "stop", tool_calls = {} },
        }, events)
        local ranked, count = models:rerank("question", { "one", "two" })
        assert.equals(2, count)
        assert.same({ { index = 2, score = 1.5 }, { index = 1, score = 0.5 } }, ranked)
        assert.equals(1, #metrics.chat)
        assert.equals(1, #metrics.rerank)
    end)

    it("reports endpoint and request-bound failures", function()
        local base = fixture()
        local models = Models.new({
            chat = { endpoint = base .. "/chat", model = "chat" },
            rerank = { endpoint = base .. "/failure", model = "reranker" },
            max_model_request_bytes = 1000,
        }, SSE)
        local ranked, failure = models:rerank("question", { "one" })
        assert.is_nil(ranked)
        assert.equals("offline", failure)
        local tiny = Models.new({
            chat = { endpoint = base .. "/chat", model = "chat" },
            rerank = { endpoint = base .. "/rerank", model = "reranker" },
            max_model_request_bytes = 1,
        }, SSE)
        local oversized, problem = tiny:rerank("question", { "one" })
        assert.is_nil(oversized)
        assert.equals("first reranker passage exceeds the request byte budget", problem)
    end)
end)
