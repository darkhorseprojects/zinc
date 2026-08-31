# Design

## Portable Agents

A Portable Agents package is operator-authored Markdown, ordinary trusted Lua modules, and package data. Exact `lua` fences form each Markdown module; every module returns one non-`nil` value. `src/` is only a physical root: public `agent.*` modules may be sealed for generated code, while `agent.internal.*` remains private.

`pa.markdown` exposes the parsed owning document, `pa.host` grants explicit files, HTTP origins, and fixed commands, and `pa.env` compiles generated text in a fresh safe environment. Generated chunks inspect sealed `package.loaded` and use real `require`; they never receive package initialization authority. An entry returns `function(input, argv)` and then a value or pull iterator. Lua/luv owns suspension, native callers drive `step` and `poll`, and each Agent is one immutable source generation.

## Zinc

Zinc identifies a request by actor, chooses temporary or durable execution, renders the real chat template and tool schema, and tokenizes that exact prompt before reserving output context. Durable Store records commit before their events, remain actor-isolated, and retain a valid UTF-8 suffix when oversized.

Retrieval gives chronological and semantic history independent exact token windows. SQLite FTS grounds terms, Cygnet expands recognized concepts, and the reranker orders bounded candidates. History and tool output are untrusted data. Generated `run_lua` tools execute in parallel, emit results in completion order, return tool messages in call order, and only a completed final model response terminates the turn.

## Build an agent for a user

Define the request, actor, terminal result, durability, authority, model budgets, retrieval, tools, and failures before code. Put operator instructions and configuration in the entry Markdown, reusable public behavior in `src/`, and implementation in `src/internal/`. Grant only required roots, origins, variables, and commands; publish only modules generated code needs. Test malformed model output, generated failures, cancellation, parallel ordering, actor isolation, and durable recovery.

## Program

```lua
local document = require("pa.markdown")()
return { guide = table.concat(document.Design.Guide, "\n\n") }
```
