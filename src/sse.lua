local module = {}

function module.new()
    local buffer, data, event = "", nil, nil
    local finished = false

    local function dispatch(records)
        if data then
            records[#records + 1] = { data = table.concat(data, "\n"), event = event }
        end
        data, event = nil, nil
    end

    local function consume(value, records)
        if value == "" then
            dispatch(records)
        elseif value:sub(1, 1) ~= ":" then
            local colon = value:find(":", 1, true)
            local field, content = value, ""
            if colon then
                field, content = value:sub(1, colon - 1), value:sub(colon + 1)
                if content:sub(1, 1) == " " then
                    content = content:sub(2)
                end
            end
            if field == "data" then
                data = data or {}
                data[#data + 1] = content
            elseif field == "event" then
                event = content
            end
        end
    end

    local function parse(final)
        local records, offset = {}, 1
        while offset <= #buffer do
            local ending = buffer:find("[\r\n]", offset)
            if not ending then
                break
            end
            local byte = buffer:byte(ending)
            if byte == 13 and ending == #buffer and not final then
                break
            end
            consume(buffer:sub(offset, ending - 1), records)
            offset = ending + (byte == 13 and buffer:byte(ending + 1) == 10 and 2 or 1)
        end
        buffer = buffer:sub(offset)
        if final then
            if buffer ~= "" then
                consume(buffer, records)
                buffer = ""
            end
            dispatch(records)
        end
        return records
    end

    local parser = {}

    function parser:push(chunk)
        assert(not finished, "SSE parser is finished")
        assert(type(chunk) == "string" and not chunk:find("%z"), "SSE chunk must be text without NUL")
        buffer = buffer .. chunk
        return parse(false)
    end

    function parser:finish()
        assert(not finished, "SSE parser is finished")
        finished = true
        return parse(true)
    end

    return parser
end

return module
