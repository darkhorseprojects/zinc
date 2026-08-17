rockspec_format = "3.0"
package = "zinc-dev"
version = "1.0-1"
source = {
    url = "git+https://github.com/darkhorseprojects/zinc.git",
}
description = {
    summary = "Development dependencies for Zinc",
    license = "Apache-2.0",
}
dependencies = {
    "lua == 5.5",
    "dkjson == 2.10-1",
    "lsqlite3 == 0.9.7-1",
    "lua-curl == 0.3.13-1",
    "luv == 1.51.0-1",
}
build = {
    type = "builtin",
    modules = {},
}
