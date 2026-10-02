# Operations

```lua
local pa = require("pa")

return setmetatable({}, {
    document = pa.document(),
    targets = { "empty" },
    __tostring = function(self)
        return tostring(getmetatable(self).document)
    end,
})
```
