local ballad = require("ballad")

return ballad.partiture(function(p)
    local layout = p:use(ballad.plugins.layout)
    local source = p.source.files({
        "zinc.md",
        "host.md",
        "design.md",
        "src/*.lua",
        "data/cygnet.db",
        "data/cygnet-index.db",
        "README.md",
        "LICENSE",
        "NOTICE",
        "models.lock",
    }, { root = "." })
    local lua = p.source.files({
        "dkjson.lua",
        "cURL/*.lua",
        "cURL/**/*.lua",
    }, { root = ".moonstone/env/share/lua/5.5" })
    local native = p.source.files({
        "lcurl.so",
        "lsqlite3.so",
        "luv.so",
    }, { root = ".moonstone/env/lib/lua/5.5" })
    local package = layout.directory({
        { from = source, to = "." },
        { from = lua, to = "vendor/share/lua/5.5" },
        { from = native, to = "vendor/lib/lua/5.5" },
    })

    p.sink.directory(package, {
        out = "dist/zinc",
        file_graph = true,
    })
end)
