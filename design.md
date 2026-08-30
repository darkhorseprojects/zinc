# Design

## Guide

A Portable Agents package is operator-authored Markdown, focused Lua modules, and data. Define request, actor, result, authority, stopping condition, and failures first. `src/` is only a physical root: public `agent.*` remains available to generated code, while trusted `agent.internal.*` does not. Each module returns one non-`nil` value; the entry returns `function(input, argv)` and then a value or pull iterator.

Trusted initialization configures `pa.host`. Generated chunks use `pa.env`, safe Lua, real `require`, and sealed `package.loaded`. Treat history and tool output as data. Keep durable records actor-isolated, apply exact model and retrieval budgets, return parallel tool results in call order, and stop only on a final model response. Native callers own allocation and raw stack values; parent processes own process policy.

## Program

```lua
local source = ...
return { guide = table.concat(require("pa.document")(source).Design.Guide, "\n\n") }
```
