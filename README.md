# Zinc

Zinc is a Portable Agents package with durable event branches, actor-isolated memory, Cygnet semantic retrieval, and parallel generated Lua tools.

## Package layout

`package/zinc.md` is the sole Portable Agents entry. It owns deployment configuration and composes three literal preset tables:

- `package/presets/unsafe.md` provides thin byte adapters over unrestricted PA hosts.
- `package/presets/safe.md` provides trusted editable wrappers rooted in `workspace/`.
- `package/presets/no-host.md` has an empty member table.

Implementation lives under `package/src/`. Construct every Agent with `sourceDir: "./package"` and `entryModule: "zinc"`; a call's opaque config selects the preset.

Release archives include Lua modules under `.lux/runtime/lua` and native modules under `.lux/runtime/lib`. Add both to Lua's module paths before invoking an ABI-compatible Lua 5.5 `agent` built with `-Dsystem-lua=true`.

## Package configuration

Edit the Lua fence in `package/zinc.md` to configure:

- Chat and rerank model origins, routes, model names, and token limits.
- Store and Cygnet paths.
- Cygnet recognition and expansion settings.
- Chronological and semantic retrieval budgets.
- Request, config, event, tool-result, and model-round limits.

Edit the corresponding literal table under `package/presets/` to replace, rename, remove, or add trusted members. Every member stores its callable function beside its model prompt. Request fields cannot define authority.

Markdown Lua fences retrieve their immutable authored document with:

```lua
local document = require("pa").document()
```

## Portable Agents config

Config is opaque to Portable Agents, but it is not opaque to Zinc. Zinc interprets it as strict UTF-8 JSON. Every field is required and unknown fields fail.

```json
{
  "version": 1,
  "actor": "account:42",
  "preset": "safe",
  "imports": {
    "research": "Research agent with documentation access.",
    "lower": "Zinc configured without host operations."
  }
}
```

| Field | Type | Contract |
|---|---|---|
| `version` | integer | Must equal `1`. |
| `actor` | string | Nonempty UTF-8 stable identity supplied by the embedder. |
| `preset` | string | Exactly `unsafe`, `safe`, or `no-host`. |
| `imports` | object | Import module names mapped to nonempty UTF-8 descriptions. Use `{}` when none are supplied. |

Config larger than `limits.config_bytes` fails. `pa` is not a valid Import name.

PA no longer assigns an Agent ID. The embedder must derive `actor` from an authenticated identity. Agents intended to share history use the same actor and package Store. Call input cannot override either actor or preset.

### Unsafe config

```json
{
  "version": 1,
  "actor": "account:42",
  "preset": "unsafe",
  "imports": {}
}
```

### Safe config

```json
{
  "version": 1,
  "actor": "account:42",
  "preset": "safe",
  "imports": {}
}
```

### No-host config

```json
{
  "version": 1,
  "actor": "account:42",
  "preset": "no-host",
  "imports": {}
}
```

## Calls

Every call is strict UTF-8 JSON with exactly three required fields:

```json
{
  "question": "Explain the current package.",
  "parent": null,
  "memory": 0
}
```

| Field | Contract |
|---|---|
| `question` | Nonempty UTF-8 string. |
| `parent` | `null` or a positive actor-owned event ID. Selects branch attachment. |
| `memory` | `0` or a positive actor-owned event ID. Selects the inclusive retrieval boundary. |

A result identifies the final assistant event:

```json
{
  "id": 42,
  "parent": 41,
  "memory": 0,
  "text": "..."
}
```

Continue from that response with `parent=42` and `memory=42`. Reusing an earlier parent creates a sibling branch. Parent and memory are independent.

## Entry functions

The entry always has `document`, `design`, and `zinc`. It also has the static union of names declared by trusted presets. A direct preset-member call dispatches through opaque config and rejects when that member is unavailable under the selected preset.

Every Eval view contains the three core members plus exactly the selected preset's members. No-host adds none. Adding a trusted safe member requires no runtime change.

The entry and PA-created proxies hide their metatables. PA already makes Markdown documents recursively read-only.

## Generated Lua

Zinc prepends `local self, input = ...` to each `run_lua` source. Generated code must not redeclare or replace those bindings. Call selected operations through `self`:

```lua
return self.document("")
```

Navigate history through the same configured Zinc entry:

```lua
return self.zinc([[
{"question":"Reconsider this event.","parent":184,"memory":184}
]])
```

Load only external caller Imports with `require`:

```lua
local lower = require("lower")
return lower([[
{"question":"Investigate without host access.","parent":184,"memory":184}
]])
```

A generated source must return exactly one non-nil string. Eval has no `pa` module or native loaders.

## Host protocols

All host requests reject unknown fields. File and process outputs must be UTF-8.

### Unsafe filesystem

Read:

```json
{"root":"/srv/data","operation":"read","path":"notes.txt"}
```

```json
{"data":"..."}
```

Write:

```json
{"root":"/srv/data","operation":"write","path":"notes.txt","data":"..."}
```

```json
{"written":true}
```

### Safe filesystem

The protocol omits `root`:

```json
{"operation":"read","path":"README.md"}
```

Safe paths are nonempty normalized relative paths. Absolute paths, backslashes, `.`, `..`, doubled separators, and trailing separators are denied. The fixed root is the dedicated `workspace/` directory; Store, Cygnet, package, model, and runtime files are outside its authority.

### Unsafe HTTP

```json
{
  "origin": "https://example.com",
  "method": "POST",
  "path": "/items",
  "body": "{}",
  "headers": {"content-type":"application/json"}
}
```

### Safe HTTP

The protocol omits `origin`:

```json
{
  "method": "GET",
  "path": "/health",
  "body": "",
  "headers": {}
}
```

The default origin is `http://127.0.0.1:8000`; only `GET` and `POST` are accepted.

Both return:

```json
{"status":200,"body":"..."}
```

### Unsafe process

```json
{
  "executable": "/usr/bin/tool",
  "arguments": ["--flag"],
  "input": ""
}
```

The executable must be an absolute path and arguments must be a dense string array.

### Safe process

```json
{"query":"event","paths":["src","tests"]}
```

The default policy runs:

```text
/usr/bin/rg -- event src tests
```

Paths follow the safe filesystem path rules and at least one path is required. No shell or arbitrary argument list is available.

Both process presets return:

```json
{"code":0,"stdout":"...","stderr":""}
```

## Imports and authority

An Import is another configured Agent. An Agent cannot import itself, so create separate Agent objects even when they use the same Zinc source and entry. Every Import carries its own config.

Caller Imports add authority independently of Zinc's local preset. The embedder must enforce the desired graph. Recommended downgrade-only arrangements are:

```text
unsafe -> safe
unsafe -> no-host
safe -> no-host
no-host -> no-host
```

`config.imports` describes actual Imports to the model; it does not create or constrain them. The caller must make the description map agree with the Imports passed to PA.

## TypeScript SDK

```ts
import { Effect } from "effect";
import * as Agent from "./portable-agents/sdk/mod.ts";

const encode = (value: unknown) =>
  new TextEncoder().encode(JSON.stringify(value));

const program = Effect.gen(function* () {
  const zinc = yield* Agent.make({
    sourceDir: "./package",
    entryModule: "zinc",
  });

  return yield* zinc.call(
    encode({
      question: "Explain the package.",
      parent: null,
      memory: 0,
    }),
    encode({
      version: 1,
      actor: "account:42",
      preset: "safe",
      imports: {},
    }),
  );
});

const output = await Effect.runPromise(program);
console.log(new TextDecoder().decode(output));
```

A lower-authority Import uses another Agent:

```ts
const unsafe = yield* Agent.make({ sourceDir: "./package", entryModule: "zinc" });
const lower = yield* Agent.make({ sourceDir: "./package", entryModule: "zinc" });

const output = yield* unsafe.call(input, unsafeConfig, [{
  name: "lower",
  agent: lower,
  config: lowerConfig,
}]);
```

The Import config uses the same actor and `preset: "no-host"` when it should share history without host authority.

## Memory

SQLite events are append-only and actor-isolated. Chronological retrieval selects actor events with `id <= memory`, fits the newest events to an exact tokenizer budget, and presents them oldest-first.

Semantic retrieval preserves Zinc's Cygnet pipeline: FTS grounding, longest recognized forms, attention filtering, relation expansion, actor/memory-bounded candidates, chronological exclusion, reranking, and an independent token budget. Recalled events retain `id`, `parent`, `memory`, `role`, and `text`.

No SQLite transaction spans model, host, Eval, process, or imported Agent work. Store and Cygnet connections close on success and failure.

Build the generated Cygnet index locked by `models.lock`:

```sh
lua tools/cygnet_index.lua SOURCE.db data/cygnet.db SOURCE_SHA256
```

The source must produce Zinc format `2` metadata.

## Parallel Lua

The model sees one `run_lua` tool with `parallel_tool_calls=true`. All calls in a nonterminal completion are submitted in one table-form `pa.eval` call. PA runs independent states concurrently and returns results in source order. Zinc persists calls and outputs in model order.

Reasoning-last and tool-last completions continue. Zinc returns only when the last normalized item is regular assistant content.

## Development

```sh
python3 tools/format_fences.py
lx --lua-version 5.5 fmt --backend stylua --path package/src
CFLAGS=-DSQLITE_ENABLE_FTS5 lx --lua-version 5.5 build
lx --lua-version 5.5 test
agent check package zinc
lua tools/benchmark.lua
```

CI builds Portable Agents from pinned commit `42c90b7d829bacfcc59c3285e0faf4898f7781ab`. Runtime use requires `agent` built with `-Dsystem-lua=true` so the native SQLite module can load.

Production executable Lua is formatted with StyLua, including fences in `package/zinc.md` and `package/presets/*.md`. Tests, tools, dependencies, and prose are excluded from production size accounting.

License: AGPL-3.0-only.
