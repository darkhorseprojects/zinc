return function(maximum)
    maximum = assert(math.tointeger(maximum), "SSE byte limit must be an integer")
    assert(maximum > 0, "SSE byte limit must be positive")
    local pending, data, event, finished = "", nil, nil, false

    local function dispatch(records)
        if data then
            records[#records + 1] = { data = table.concat(data, "\n"), event = event }
        end
        data, event = nil, nil
    end
    local function consume(line, records)
        if line == "" then
            dispatch(records)
        elseif line:sub(1, 1) ~= ":" then
            local colon = line:find(":", 1, true)
            local field, value = line, ""
            if colon then
                field, value = line:sub(1, colon - 1), line:sub(colon + 1)
                if value:sub(1, 1) == " " then
                    value = value:sub(2)
                end
            end
            if field == "data" then
                data = data or {}
                data[#data + 1] = value
            elseif field == "event" then
                event = value
            end
        end
    end
    local function parse(final)
        local records, offset = {}, 1
        while offset <= #pending do
            local ending = pending:find("[\r\n]", offset)
            if not ending or pending:byte(ending) == 13 and ending == #pending and not final then
                break
            end
            consume(pending:sub(offset, ending - 1), records)
            offset = ending + (pending:byte(ending) == 13 and pending:byte(ending + 1) == 10 and 2 or 1)
        end
        pending = pending:sub(offset)
        assert(#pending <= maximum, "SSE line exceeds configured byte limit")
        if final then
            if pending ~= "" then
                consume(pending, records)
            end
            pending = ""
            dispatch(records)
        end
        return records
    end
    return {
        push = function(_, chunk)
            assert(not finished, "SSE parser is finished")
            assert(type(chunk) == "string" and not chunk:find("%z"), "invalid SSE chunk")
            pending = pending .. chunk
            return parse(false)
        end,
        finish = function()
            assert(not finished, "SSE parser is finished")
            finished = true
            return parse(true)
        end,
    }
end
