local active
local public = {
    available = function()
        return active ~= nil and active.durable
    end,
    read = function(id)
        return active and active.durable and active.read(id) or nil
    end,
    around = function(id)
        return active and active.durable and active.around(id) or nil
    end,
    ask = function(request)
        assert(active and active.durable, "durable history is unavailable")
        return active.ask(request)
    end,
}

return function()
    package.loaded["zinc.history"] = public
    return public,
        function(thread, context, ...)
            local previous = active
            active = context
            local result = table.pack(coroutine.resume(thread, ...))
            active = previous
            return table.unpack(result, 1, result.n)
        end
end
