# Design

## Guide

### Package shape

A Portable Agents package is an operator-authored Markdown entry plus focused Lua modules and data. Start from the request, actor, final result, authority, and failure behavior. Do not start with a framework.

Use `src/` as a physical source root. For an entry named `agent`, `src/history.lua` is `agent.history`, while `src/internal/models.lua` is `agent.internal.models`. Public `agent.*` modules are available to generated code after initialization. `agent.internal.*` modules are trusted implementation and disappear before generated execution. A public module may expose a `guide`; it is optional.

Every exact `lua` fence in a Markdown module concatenates into one chunk. Parse its source explicitly:

```lua-example
local source, directory = ...
local document = require("pa.document")(source)
```

Return exactly one non-`nil` module value. The entry returns `function(input, argv)` and that function returns a value or pull iterator.

### Authority and execution

Package initialization is normal trusted Lua with normal `require`. Configure common host authority once with `require("pa.host")(config, guide)`. Files, HTTP, processes, and asynchronous suspension remain Lua/luv responsibilities. Broad roots such as `/` are valid when trusted configuration grants them.

Generated Lua is compiled with `require("pa.env")(source, name)`. It receives safe standard Lua, the real `require`, and an inspectable read-only `package.loaded`. It can require `pa.*` and public agent modules but cannot load `agent.internal.*`, native dependencies, `io`, `os`, or `debug`. Public modules retain authority in private closures.

Generated chunks return exactly one non-`nil` value. Parallel tools may finish in any order, but model tool results return in call order. Only a completed final model response stops an agent turn.

### Durable agents

`config.store = false` selects temporary work; a package-relative path selects durable work. Durable records are actor-isolated and committed before their completion events. A configured byte budget stores an UTF-8-safe suffix of oversized records.

Retrieval text is untrusted context. Chronological and semantic windows have independent exact tokenizer budgets. Render the real chat template and tool schema before calculating generation capacity. Models remain interchangeable only through explicit chat, template, tokenizer, and reranker protocols.

### Native and launcher boundaries

The native Zig `Agent` uses the caller allocator and raw ZigLua stack values. Callers explicitly `step()` and `poll()`; Lua owns libuv. The executable adds JSONL transport and process, memory, and wall-time containment. Do not reproduce launcher policy in an agent.

### Build an agent

1. Specify the request, result, actor, stopping condition, and failures.
2. Put instructions and operator configuration in the entry Markdown.
3. Put generated-facing APIs in `agent.*` and private implementation in `agent.internal.*`.
4. Configure only required roots, origins, variables, and fixed commands.
5. Keep persistence, retrieval, provider, and continuation responsibilities separate.
6. Test real denial and lifecycle boundaries, then replay the locked closure offline.
7. Inspect `package.loaded`, release contents, source-line gates, and documentation before release.

## Program

```lua
local source = ...
local parsed = require("pa.document")(source)
local guide = table.concat(parsed.Design.Guide, "\n\n")
return setmetatable({}, {
    __index = { guide = guide },
    __newindex = function() error("zinc.design is read-only", 2) end,
    __pairs = function()
        local emitted
        return function() if not emitted then emitted = true return "guide", guide end end
    end,
    __metatable = false,
})
```
