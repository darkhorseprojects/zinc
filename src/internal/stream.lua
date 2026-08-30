return function(iterator, ...)
    local value = iterator(...)
    while type(value) == "function" do
        value = iterator(coroutine.yield(value))
    end
    return value
end
