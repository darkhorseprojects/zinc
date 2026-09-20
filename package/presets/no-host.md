# Operations

```lua
local pa = require("pa")

local function prompt(parent, memory)
    parent = parent and tostring(parent) or "nil"
    return string.format(
        [[self({preset=P,question=Q,parent=%s,memory=%d}) -> {branch,id,parent,memory,text}
P = nil | "no-host"
self.destroy(branch) -> "destroyed"
local r=self({question="QUESTION",parent=%s,memory=%d}); self.destroy(r.branch); return r.text]],
        parent,
        memory,
        parent,
        memory
    )
end

return {
    document = pa.document(),
    targets = { "no-host" },
    prompt = prompt,
    whitelist = {},
    members = {},
}
```
