# Design

## Guide

A Portable Agents package is operator-authored Markdown, focused Lua modules, and data. Define its request, actor, result, authority, stopping condition, and failures before writing code. The entry returns `function(input, argv)`; that function returns a value or pull iterator.

`src/` is only a physical root: `src/history.lua` maps to `agent.history`, and `src/internal/models.lua` to trusted `agent.internal.models`. Public `agent.*` modules remain available to generated code; internal modules do not. Exact `lua` fences concatenate, and each module returns one non-`nil` value. Parse Markdown explicitly with `require("pa.document")(source)`.

Trusted initialization has normal Lua and configures `pa.host` once. Generated chunks use `require("pa.env")(source, name)`, safe Lua globals, real `require`, and the sealed public `package.loaded`; they receive no `io`, `os`, `debug`, native modules, or internal modules. Authority retained by a public module stays in its private closures.

Durable records are actor-isolated and committed before completion events. Stored text has an explicit UTF-8-safe byte policy. Retrieved text and tool output are untrusted. Chronological, semantic, reranker, and generation windows use their exact tokenizer and rendered template budgets. Parallel tools emit by completion but return to the model in call order; only a final model response ends the turn.

The native Zig `Agent` uses its caller's allocator and raw ZigLua stack values through `step()` and `poll()`. Lua owns libuv. JSONL, process memory, and hard wall time belong only to the executable launcher.

## Program

```lua
local source = ...
local guide = table.concat(require("pa.document")(source).Design.Guide, "\n\n")
return { guide = guide }
```
