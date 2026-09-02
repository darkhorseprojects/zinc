# Design

## Portable Agents

A Portable Agents package is operator-authored Markdown, trusted Lua modules, and package data. Exact `lua` fences form Markdown modules, and every module returns one non-`nil` value. `src/` is only a physical root: public `zinc.*` modules may be sealed for generated code, while `zinc.internal.*` remains private.

`pa.markdown` exposes the parsed owning document, `pa.host` grants canonical roots, exact HTTP origins, and configured process shapes, and `pa.env` compiles generated text in a fresh safe environment. Generated chunks inspect the read-only sealed `package.loaded` and use real `require`; they never receive package initialization authority. An entry returns `function(input, argv)` and then a value or pull iterator. Pulls are blocking and thread-affine. Lua/luv owns direct process handles, pipes, timers, callbacks, and progress.

Authority is configured statically. File and HTTP limits are optional per call and otherwise unbounded at that layer. Every process call supplies timeout and stdin/stdout/stderr limits. Each process shape fixes its executable, argv template, cwd, and child-to-Agent environment mapping. Process aliases are not callable. PA supervises the direct child and makes no descendant-termination promise.

## Zinc

Zinc identifies a request by actor, renders the actual chat template and tool schema, and tokenizes that prompt before generation. Model identity and context are static facts. Output, model-call, tool, event, HTTP, record, and retrieval limits are optional invocation data. One supplied model-call counter is shared by root turns and nested `history.ask` calls.

Zinc builds a deterministic capability section after package sealing. It lists public modules and guides plus concrete host roots, origins, programs, argument templates, working directories, and child environment names. Mounted modules such as Discord appear generically through `package.loaded`; Zinc contains no Discord-specific behavior or secrets.

Durable Store records commit before their events and remain actor-isolated. Retrieval gives independent chronological row/token and semantic limits. SQLite FTS grounds terms, Cygnet expands recognized concepts, and the reranker orders candidates. Missing limits are unbounded. Retrieved history and tool output remain untrusted data.

Generated `run_lua` tools execute sequentially in model order. Compilation, runtime, capability usage, return-shape, UTF-8, and encoding errors become failed tool results so the model can correct them. Model protocol, database, budget, and Agent lifecycle failures remain terminal. Only a completed final model response ends a turn.

## Build an agent for a user

Define the request, actor, terminal result, durability, authority, invocation budgets, retrieval, tools, and failures before code. Put behavior in `zinc.md`, host authority in `host.md`, reusable public behavior in `src/`, and implementation in `src/internal/`. Grant only required roots, origins, process shapes, and per-command environment mappings. Publish only modules generated code needs. Test malformed model output, generated failures, cancellation, sequential ordering, actor isolation, and durable recovery.

## Program

```lua
local document = require("pa.markdown")()
return { guide = table.concat(document.Design, "\n\n") }
```
