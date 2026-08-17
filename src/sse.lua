local module = {}

function module.new()
    local fragments, data, event = {}, nil, nil
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
        local records, source, offset = {}, table.concat(fragments), 1
        fragments = {}
        while offset <= #source do
            local ending = source:find("[\r\n]", offset)
            if not ending then
                break
            end
            local byte = source:byte(ending)
            if byte == 13 and ending == #source and not final then
                break
            end
            consume(source:sub(offset, ending - 1), records)
            offset = ending + (byte == 13 and source:byte(ending + 1) == 10 and 2 or 1)
        end
        if offset <= #source then
            fragments[1] = source:sub(offset)
        end
        if final then
            if fragments[1] then
                consume(fragments[1], records)
                fragments = {}
            end
            dispatch(records)
        end
        return records
    end

    local parser = {}

    function parser:push(chunk)
        assert(not finished, "SSE parser is finished")
        assert(type(chunk) == "string" and not chunk:find("%z"), "SSE chunk must be text without NUL")
        fragments[#fragments + 1] = chunk
        if chunk:find("[\r\n]") or #fragments > 1 and fragments[#fragments - 1]:sub(-1) == "\r" then
            return parse(false)
        end
        return {}
    end

    function parser:finish()
        assert(not finished, "SSE parser is finished")
        finished = true
        return parse(true)
    end

    return parser
end

return module
