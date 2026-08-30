local sse = require("zinc.internal.sse")

describe("SSE", function()
    it("handles every byte boundary and an unterminated final record", function()
        local parser = sse()
        local source = ": keepalive\r\nevent: token\r\ndata: first\r\ndata: 😀\r\n\r\ndata: [DONE]"
        local records = {}
        for index = 1, #source do
            for _, record in ipairs(parser(source:sub(index, index))) do
                records[#records + 1] = record
            end
        end
        for _, record in ipairs(parser()) do
            records[#records + 1] = record
        end
        assert.same({
            { data = "first\n😀" },
            { data = "[DONE]" },
        }, records)
    end)

    it("handles LF, CR, and empty data lines", function()
        local parser, records = sse(), {}
        for _, chunk in ipairs({ "data: one\n\n", "data:\rdata: three\r\r" }) do
            for _, record in ipairs(parser(chunk)) do
                records[#records + 1] = record
            end
        end
        for _, record in ipairs(parser()) do
            records[#records + 1] = record
        end
        assert.same({ { data = "one" }, { data = "\nthree" } }, records)
    end)
end)
