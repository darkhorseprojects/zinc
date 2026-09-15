local json = require("lunajson")

local codec = { null = {} }

function codec.decode(source, maximum)
    assert(type(source) == "string" and (not maximum or #source <= maximum) and utf8.len(source), "invalid JSON bytes")
    local value, offset = json.decode(source, 1, codec.null)
    assert(source:sub(offset):match("^%s*$"), "JSON has trailing data")
    return value
end

function codec.object(source, fields, maximum)
    local value = codec.decode(source, maximum)
    assert(type(value) == "table", "JSON value must be an object")
    for key in pairs(value) do
        assert(fields[key], "unknown JSON field")
    end
    return value
end

function codec.encode(value)
    return json.encode(value, codec.null)
end

return codec
