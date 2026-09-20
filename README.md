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

Opaque config is strict UTF-8 JSON with exactly these fields:

```json
{
  "version": 1,
  "actor": "account:42",
  "preset": "safe",
  "quota": null,
  "imports": {
    "research": "Research agent."
  }
}
```

- `version` is `1`.
- `actor` is a nonempty authenticated identity.
- `preset` is `unsafe`, `safe`, or `no-host`.
- `quota` is `null` for the package default or a positive per-run override.
- `imports` maps configured PA Import names to concise descriptions.

The default quota is configured in `package/zinc.md`.

## Calls

Root input remains exactly:

```json
{"question":"...","parent":null,"memory":0}
```

`parent` is `null` or an actor-owned event ID. `memory` is an independent inclusive actor-owned event boundary, with `0` selecting no history.

A root result remains:

```json
{"id":42,"parent":41,"memory":0,"text":"..."}
```

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

Configured Imports appear under `self.agents`:

```lua
local result = self.agents["research"].call({
    question = "Find the source.",
    parent = nil,
    memory = 0,
})
return result.text
```

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

Store format `5` normalizes state into runs, branches, and events:

- runs own actor and budget
- branches own run, base, memory, preset, and lifetime
- events own branch, kind, text, and optional tool token count

No migration is performed. Format `0` initializes; format `5` opens; every other version fails.

Normal retrieval sees durable actor events. A temporary branch also sees its own temporary ancestry. Chronological and semantic retrieval remain bounded by the inclusive memory coordinate. Cygnet format `2` and `relation-balanced-pagerank-v1` remain required.

No SQLite transaction spans model, HTTP, process, Eval, or imported-Agent work.

## Models

`models.ini` configures LFM2.5-2.6B with its official generation settings:

```text
temperature = 0.1
top-k = 50
repetition penalty = 1.1
```

Chat uses the embedded Jinja template through non-stream `/v1/chat/completions`. Reranking uses the locked Nemotron reranker.

Models remain external to release archives. Build Cygnet data with:

```sh
lua tools/cygnet_index.lua SOURCE.db data/cygnet.db SOURCE_SHA256
```

## Benchmarks

The matched evaluation protocol for LongMemEval-V2, MemoryArena, and BEAM is in [`BENCHMARKS.md`](BENCHMARKS.md). LongMemEval-V2 calls its largest public tier `medium`; it has no public `large` tier.

## Development

```sh
python3 tools/format_fences.py
lx --lua-version 5.5 fmt --backend stylua --path package/src
CFLAGS=-DSQLITE_ENABLE_FTS5 lx --lua-version 5.5 build
agent check package zinc
lx --lua-version 5.5 lua tools/retrieval_smoke.lua
```

CI pins Portable Agents commit `d95476b7638480108175cd1b9026ee02559c1714`.

License: AGPL-3.0-only.
