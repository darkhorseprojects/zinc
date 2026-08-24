local Store = require("src.store")

local directory, actor, count = assert(arg[1]), assert(arg[2]), assert(math.tointeger(tonumber(arg[3])))
local store = Store.open({
    package_directory = directory,
    path = "store/zinc.db",
    max_stored_record_bytes = 1000,
})
for index = 1, count do
    local request = store:begin(actor, "request " .. index)
    store:append(actor, request.id, "assistant", "response " .. index)
end
store:close()
