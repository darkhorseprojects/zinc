local active
local public = {
    read = function(id) return active and active.durable and active.read(id) or nil end,
    around = function(id) return active and active.durable and active.around(id) or nil end,
    ask = function(request)
        assert(active and active.durable, "durable history is unavailable")
        return active.ask(request)
    end,
}

return function()
    package.loaded["zinc.history"] = public
    return public, function(context, work, ...)
        local previous = active
        active = context
        local result = table.pack(pcall(work, ...))
        active = previous
        assert(result[1], result[2])
        return table.unpack(result, 2, result.n)
    end
end
