local M = {}

local function join(separator, ...)
    return table.concat({ ... }, separator)
end

local function prepend(current, patterns)
    return table.concat(patterns, ";") .. ";" .. current
end

function M.activate(package_directory)
    assert(type(package_directory) == "string" and package_directory ~= "", "package directory is required")
    local separator = package.config:sub(1, 1)
    local share = join(separator, package_directory, "vendor", "share", "lua", "5.5")
    local native = join(separator, package_directory, "vendor", "lib", "lua", "5.5")
    package.path = prepend(package.path, {
        join(separator, share, "?.lua"),
        join(separator, share, "?", "init.lua"),
    })
    package.cpath = prepend(package.cpath, {
        join(separator, native, "?.so"),
        join(separator, native, "?.dylib"),
        join(separator, native, "?.dll"),
    })
end

return M
