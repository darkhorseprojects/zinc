return function(message)
    assert(type(message) == "table" and type(message.content) == "string", "final provider message has no text")
    local content = message.content:match("^%s*(.-)%s*$")
    assert(content ~= "", "final provider message has no text")
    local characters = assert(utf8.len(content), "Discord message is not valid UTF-8")
    assert(characters <= 2000, "Discord message exceeds 2000 characters")
    return content
end
