# Zinc

Zinc is a Portable Agents package with actor-isolated durable memory, Cygnet semantic retrieval, configured Lua capabilities, concurrent Eval tools, temporary nested branches, and Store-backed tool-token quotas.

## Package

`package/zinc.md` is the sole entry. Production modules are:

```text
package/zinc.md
package/design.md
package/presets/{unsafe,safe,no-host}.md
package/src/{entry,memory,model,run,store}.lua
```

Construct Agents with `sourceDir: "./package"` and `entryModule: "zinc"`. Portable Agents must be built with ABI-compatible dynamic Lua 5.5 through `-Dsystem-lua=true`.

## Config

Opaque config is strict UTF-8 JSON. The only required fields are:

```json
{"version":1,"actor":"account:42","preset":"safe"}
```

`actor` is a nonempty authenticated identity; `preset` is `unsafe`, `safe`, or `no-host`. Optional `parent` and `memory` select explicit actor-owned coordinates and must be supplied together. Optional nested `run`, `models`, and `retrieval` objects override the defaults in `package/zinc.md`. For example:

```json
{
  "run": {"quota_tokens":12000,"max_model_rounds":12},
  "models": {"chat":{"maximum_output_tokens":2048,"thinking":false}},
  "retrieval": {"chronological":{"tokens":8000},"semantic":{"candidates":24}}
}
```

All nested keys are validated against the package defaults; unspecified values remain unchanged. PA resource ceilings and Connector concurrency are separate embedder policy, not Zinc config. Imports are discovered from PA grants and documented by each required module.

## Calls

Root input is the nonempty UTF-8 question. When `parent` and `memory` are absent from config, Zinc continues from the
latest durable response owned by `actor`; a new actor starts with no history. Set both fields for an explicit branch:

```json
{"parent":42,"memory":42}
```

`parent` may be `null`; `memory` is an inclusive event boundary with `0` selecting no history. Root output is the final
Markdown response with a subdued Store-coordinate footer. With PA streaming enabled, Zinc first emits stored reasoning
as blockquotes, stored intermediate responses as Markdown, tool calls as Lua fences, and tool results as text fences.

## Presets

Preset Markdown is included in the selected model prompt and contains only operational instructions. Preset Lua owns the actual whitelist, exact Lua signatures, trusted Eval adapters, and implementations.

The default configured preset exposes:

```text
root home = $HOME [read, write, search]
HTTP model_health = GET http://127.0.0.1:8000/health
HTTP model_models = GET http://127.0.0.1:8000/v1/models
```

Edit `package/presets/safe.md` to change those values. “Safe” means configured.

The unsafe preset accepts caller-selected filesystem roots, HTTP coordinates, and absolute process executables. No-host adds no filesystem, HTTP, search, or process member.

## Generated Lua

Generated code receives native Lua `self` and `input`. JSON is not part of the public capability API.

```lua
local text = self.fs.read("home", "notes.txt")
self.fs.write("home", "copy.txt", text)
return text
```

```lua
local response = self.http.call("model_health", "", {})
return response.body
```

```lua
return self.search.text("home", "dev/zinc", "event")
```

Granted Imports are native Lua modules, accessed only through `require`:

```lua
local discord = require("discord")
local id = discord.create_message("hello")
return id
```

Each Import supplies its own `document()` member for generated prompt instructions.

Each `run_lua` source returns one Lua value. Portable Agents renders complete table results as Lua, while string results remain unchanged. Independent sources in one model response execute concurrently and return in model order.

## Nested Zinc

Nested calls create temporary branches:

```lua
local child = self({
    preset = "no-host",
    question = "Check the evidence.",
    parent = input.parent,
    memory = input.memory,
})
return child.text
```

Allowed targets are:

```text
unsafe  -> unsafe, safe, no-host
safe    -> safe, no-host
no-host -> no-host
```

Continue an investigation by using its returned `id` as the next `parent` and `memory`. To inspect and remove it in one source:

```lua
local child = self({
    preset = "no-host",
    question = "Check the evidence.",
    parent = input.parent,
    memory = input.memory,
})
local text = child.text
self.destroy(child.branch)
return text
```

Destruction removes the selected temporary branch and descendants. Durable parent call sources, results, and final responses remain.

## Quota

Quota counts exact chat-tokenizer tokens in:

- accepted model-generated Lua source
- the complete result or traceback from that accepted source

It does not count questions, prompts, memory, reasoning, regular responses, trusted adapter source, or quota metadata.

A source is admitted only when its tokens fit the committed remaining quota. Accepted results are always stored in full and may make the balance negative. Later sources are rejected when they do not fit.

The first prompt contains the current balance. After every tool wave, the final tool message receives nonpersistent `quota_remaining=N` metadata. Nested loops derive the same run through their caller Store event; no quota value is passed recursively.

## Store and memory

Store format `1` normalizes state into runs, branches, and events:

- runs own actor and budget
- branches own run, base, memory, preset, lifetime, and the successful terminal response coordinate
- events own branch, kind, text, and optional tool token count

No migration is performed. Format `0` initializes version `1`; version `1` opens; every other version fails. Incomplete durable branches remain auditable but cannot become the continuation head or enter normal retrieval.

Normal retrieval sees durable actor events. A temporary branch also sees its own temporary ancestry. Chronological and semantic retrieval remain bounded by the inclusive memory coordinate. Cygnet format `2` and `relation-balanced-pagerank-v1` remain required.

No SQLite transaction spans model, HTTP, process, Eval, or imported-Agent work.

## Models

`models.ini` configures MiniCPM5-2B Q4_K_M with its recommended generation settings:

```text
temperature = 1.0
top-p = 0.95
min-p = 0.0
```

Its 65,536-token router context fits the default combined retrieval budgets and output ceiling; the model supports up to 131,072 tokens. The pinned local llama.cpp fork includes the specialized MiniCPM5 XML tool-call parser.

Chat uses the embedded Jinja template through non-stream `/v1/chat/completions`. Reranking uses the locked Nemotron reranker.

Models remain external to release archives. `models.ini` identifies their Hugging Face repositories and files; the
router resolves them through the standard Hugging Face cache. Build Cygnet data with:

```sh
lua tools/cygnet_index.lua SOURCE.db data/cygnet.db SOURCE_SHA256
```

## Agent Connector

The tracked `ac.yaml` defines the Zinc policy. Fill a member, channel, or guild route, then connect and run:

```sh
../llama.cpp-nemotron/build/bin/llama-server --models-preset models.ini --port 8000
agc connect .
agc check .
agc run .
```

Connector expands the configured actor, supplies the optional Discord Import, streams Zinc's emitted Markdown, and
passes per-command config overlays without interpreting Zinc's schema. Zinc owns continuation in its Store. PA discovers pure Lua modules in the package Image and native modules under `package/native`. No Lua loader environment variables are needed. The PA binary and native module must both use ABI-compatible dynamic Lua 5.5.

## Development

```sh
python3 tools/format_fences.py
lx --lua-version 5.5 fmt --backend stylua --path package/src
CFLAGS=-DSQLITE_ENABLE_FTS5 lx --lua-version 5.5 build
mkdir -p package/native
cp "$(find .lux/5.5 -path '*/lib/lsqlite3complete.so' -type f -print -quit)" package/native/
agent check package zinc
```

Zinc requires Portable Agents protocol 1 with optional `pa.emit` support. CI pins commit
`114e6fa5c395541e0ac2b435f38a2877c34d5cb9`.

License: AGPL-3.0-only.
