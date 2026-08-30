return function()
    local pending, data = "", nil

    local function dispatch(records)
        if data then
            records[#records + 1] = { data = table.concat(data, "\n") }
        end
        data = nil
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
        if final then
            if pending ~= "" then
                consume(pending, records)
            end
            pending = ""
            dispatch(records)
        end
        return records
    end
    return function(chunk)
        if chunk ~= nil then
            assert(type(chunk) == "string" and not chunk:find("%z"), "invalid SSE chunk")
            pending = pending .. chunk
        end
        return parse(chunk == nil)
    end
end
