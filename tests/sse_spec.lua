local sse = require("src.sse")

describe("SSE", function()
    it("handles every byte boundary and an unterminated final record", function()
        local parser = sse(1024)
        local source = ": keepalive\r\nevent: token\r\ndata: first\r\ndata: 😀\r\n\r\ndata: [DONE]"
        local records = {}
        for index = 1, #source do
            for _, record in ipairs(parser:push(source:sub(index, index))) do
                records[#records + 1] = record
            end
        end
        for _, record in ipairs(parser:finish()) do
            records[#records + 1] = record
        end
        assert.same({
            { data = "first\n😀", event = "token" },
            { data = "[DONE]" },
        }, records)
    end)

    it("handles LF, CR, and empty data lines", function()
        local parser, records = sse(1024), {}
        for _, chunk in ipairs({ "data: one\n\n", "data:\rdata: three\r\r" }) do
            for _, record in ipairs(parser:push(chunk)) do
                records[#records + 1] = record
            end
        end
        for _, record in ipairs(parser:finish()) do
            records[#records + 1] = record
        end
        assert.same({ { data = "one" }, { data = "\nthree" } }, records)
    end)

    it("enforces its byte limit and lifecycle", function()
        local parser = sse(1024)
        assert.has_error(function()
            parser:push(string.rep("x", 100000))
        end, "SSE line exceeds configured byte limit")
        local finished = sse(1024)
        finished:finish()
        assert.has_error(function()
            finished:push("x")
        end, "SSE parser is finished")
        assert.has_error(function()
            finished:finish()
        end, "SSE parser is finished")
    end)
end)
