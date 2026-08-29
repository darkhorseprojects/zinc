# Design

## Guide

### The package is the agent

A Portable Agents package is a Markdown entry document plus the Lua modules and data it closes over. Start with the job: identify the request, actor, final result, required authority, and observable failure behavior. Do not begin with a framework or a generic agent class.

The entry document is operator-authored. It should contain the instructions the model must follow, the root configuration an operator may change, and a short Program that assembles the package. Reusable behavior belongs in focused Lua modules.

Every exact `lua` fence in the entry document is concatenated into one Lua chunk. Locals therefore cross fences. The document must return exactly one non-`nil` value, normally an entry function:

```lua-example
return function(input, argv)
    return run(input, assert(argv[1], "actor is required"))
end
```

The entry receives UTF-8 `input` and string arguments. It returns one portable value or a pull iterator. An iterator yields values, asynchronous suspension functions, and eventually `nil`. The caller owns process supervision and cancellation.

### Portable Agents owns containment

Portable Agents supplies three public Lua modules:

- `pa.document` exposes the parsed Markdown document.
- `pa.env` creates a fresh explicit environment for generated Lua.
- `pa.host` constructs only the host capabilities granted by root configuration.

The launcher owns source loading, memory and time limits, JSONL transport, process containment, and package closure resolution. Agent code should not reproduce those responsibilities.

Host authority is explicit. Configure exact file roots, HTTP origins, environment names, and fixed command vectors. Generated code must never receive ambient `io`, `os`, `debug`, FFI, native searchers, writable shared caches, or an unrestricted shell. A trusted physical module may use its own dependencies and return a narrower capability.

Construct host access directly from root configuration:

```lua-example
local host = require("pa.host")(config.host, document.Agent.Capabilities)
```

Do not add registries, capability frameworks, settings layers, or translated option tables. Pass the unchanged root config to package modules. Pass a reusable dependency only the subtable it owns.

### Zinc owns continuation

Zinc adds a model-driven continuation loop to PA. A turn starts with instructions, optional untrusted historical context, and the current user request. The model may stream reasoning, stream a response, or request `run_lua`. Only a completed final response stops the turn.

Each generated tool body is loaded into a new `pa.env` projection. Capabilities are ordinary Lua values discovered through `package.loaded`; substantial ones expose a `guide`. Generated code returns exactly one non-`nil` value. Zinc serializes that value and sends it back as the matching tool result.

Parallel calls execute concurrently. Results are exposed as work completes, then appended to the model conversation in original call order. Provider, protocol, persistence, authority, and stopping failures remain failures. Do not manufacture a successful answer when a required dependency failed.

### Persistence and retrieval are optional

`config.store = false` makes a temporary turn. A package-relative database filename enables durable work. Both modes use the same continuation loop.

Durable mode commits each completed request, reasoning item, response, tool call, and tool result before exposing its completion event. A later failure does not erase earlier completed records. Unfinished work has no terminal record. Actor isolation is enforced in every historical read.

Retrieval combines two independent windows:

- newest chronological records, restored to chronological order;
- older lexical candidates expanded through Cygnet and ordered by the reranker.

Retrieved records are untrusted context, never instructions. Model tokenizers bound both windows. Final prompt accounting includes the chat template and tool schema. A request fails before inference if the complete prompt leaves too little response capacity.

### Modules should own one responsibility

Use native Lua factories and tables:

```lua-example
return function(config, dependency)
    local api = {}
    function api:operation(value)
        return value
    end
    return api
end
```

A module returning one constructor returns the constructor directly. A cohesive runtime returns its operations in one table. Add a file only when it owns a distinct responsibility or removes duplication. Avoid `.new` ceremony, lifecycle wrappers, compatibility APIs, and helpers that merely rename language behavior.

Zinc's split is representative:

- `models.lua`: provider protocols, template rendering, tokenization, chat streaming, reranking;
- `store.lua`: durable records, actor isolation, lexical search;
- `cygnet.lua`: semantic graph expansion;
- `retrieval.lua`: context selection and token budgets;
- `run.lua`: continuation, generated tools, persistence events;
- `sse.lua`: bounded event-stream parsing.

### Build another agent

1. Write one realistic request and the ideal final result.
2. Decide whether the actor and durable history matter.
3. List every file root, origin, command, variable, credential, and side effect required.
4. Put model instructions and operator configuration in the entry Markdown.
5. Put reusable behavior in the smallest set of Lua modules with distinct ownership.
6. Construct narrow host capabilities and expose guides only where generated code needs them.
7. Assemble modules in a short Program and return one entry function.
8. Run `agent check` with the exact mounts and trusted modules used in production.
9. Test authority denial, cancellation, malformed provider output, tool failure, and the final result contract.
10. Build the closure offline and inspect the release tree.

A useful acceptance test crosses a real boundary. Prefer a disposable process, real SQLite database, actual package closure, or live model protocol over a test that repeats a helper's branches.

### Completion rules

Before release, verify that:

- the request, actor, result, and stopping condition are explicit;
- instructions and retrieved text have different authority;
- every host grant is necessary and visible;
- generated Lua receives only intended values;
- temporary execution writes nothing;
- durable completions commit before exposure;
- token, byte, memory, time, and concurrency limits are enforced by their owning layer;
- pinned dependencies replay without a package server;
- cancellation reaches descendant work;
- tests and documentation describe the implementation that ships.

## Program

```lua
return { guide = document.Design.Guide }
```
