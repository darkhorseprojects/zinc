return function()
    local pending, data = "", {}
    return function(chunk)
        local final = chunk == nil
        if not final then
            assert(type(chunk) == "string" and not chunk:find("%z"), "invalid SSE chunk")
            pending = pending .. chunk
        end
        local records, offset = {}, 1
        local function consume(line)
            if line == "" then
                if #data > 0 then
                    records[#records + 1] = { data = table.concat(data, "\n") }
                    data = {}
                end
            else
                local value = line == "data" and "" or line:match("^data: ?(.*)$")
                if value then
                    data[#data + 1] = value
                end
            end
        end
        while offset <= #pending do
            local ending = pending:find("[\r\n]", offset)
            if not ending or pending:byte(ending) == 13 and ending == #pending and not final then
                break
            end
            consume(pending:sub(offset, ending - 1))
            offset = ending + (pending:sub(ending, ending + 1) == "\r\n" and 2 or 1)
        end
        pending = pending:sub(offset)
        if final then
            if pending ~= "" then
                consume(pending)
            end
            pending = ""
            consume("")
        end
        return records
    end
end
