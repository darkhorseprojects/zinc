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

`package/` is the tracked PA source. Lux builds its locked Lua dependencies; CI assembles them and the source into `dist/zinc/package/`, with `ac.yaml`, model configuration, and Cygnet data at the release root. Release archives install that layout as `package/` beneath the Zinc directory. Use `entryModule: "zinc"`. Portable Agents must be built with ABI-compatible dynamic Lua 5.5 through `-Dsystem-lua=true`.

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

All nested keys are validated against the package defaults; numeric defaults are trusted upper bounds for per-call
overrides except a higher semantic attention cutoff, which narrows retrieval. Connector grants caller control only over the top-level paths listed in its policy's `overrides`; the tracked
policy seals `actor`, `preset`, and `version`. An installed policy without `overrides` denies per-call changes until its
operator explicitly grants them. The trusted `model` table in `package/zinc.md` configures the origin and chat, rerank, and tokenizer paths. They are not opaque per-call overrides: letting a caller redirect model requests would expose private history to another server. The safe preset's allowed HTTP actions remain independent. PA resource ceilings and Connector concurrency are separate embedder policy, not Zinc config. Imports are discovered from PA grants and documented by each required module.

## Calls

Root input is the nonempty UTF-8 question. When `parent` and `memory` are absent from config, Zinc continues from the
latest durable response owned by `actor`; a new actor starts with no history. Set both fields for an explicit branch:

```json
{"parent":42,"memory":42}
```

`parent` may be `null`; `memory` is an inclusive event boundary with `0` selecting no history. Root output is the final
Markdown response with a subdued Store-coordinate footer. With PA streaming enabled, Zinc appends model content or quoted reasoning as it arrives, then sends complete tool calls as Lua fences and bounded tool results as text fences. The Store marks a terminal result only after a complete model turn.

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
- the bounded result or traceback representation from that accepted source

It does not count questions, prompts, memory, reasoning, regular responses, trusted adapter source, or quota metadata.

A source is admitted only when its tokens fit the committed remaining quota. Results longer than `run.maximum_tool_result_bytes` are UTF-8 truncated with their call coordinate and original byte count; if a bounded result exceeds the remaining token quota, a zero-token omission marker is stored instead. The Store refuses metered writes that would overdraw the run. Existing historical rows are preserved.

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

`models.ini` configures Prism's Ternary Bonsai 2 27B PQ2_0 with its Q8 vision projector, 131,072 context tokens, Q4 KV cache, and the BAAI BGE reranker v2 M3 Q8_0. Generation uses temperature 1.0, top-k 20, top-p 0.95, min-p 0.05, and repeat penalty 1.0. The projector stays in host RAM to preserve VRAM. The Prism llama.cpp release pinned in `models.lock` is required; upstream and the Nemotron fork cannot run these weights.

The reranker has a separate 4,096-token slot. Default retrieval reserves up to 30,000 tokens each for chronological and semantic history (256 records and 64 candidates); available history may be smaller. Before every chat round Zinc applies the server's template with the tool schema, counts its tokens, reserves output, 4,096 tokens of headroom, and 4,096 tokens per attached image, then discards the oldest complete transient tool waves if necessary. The system, question, and retrieved history remain intact; an oversized base prompt fails rather than silently truncating. Numeric overrides cannot exceed the trusted package defaults. The model advertises 262,144 tokens, but this preset qualifies 131,072; longer contexts require separate VRAM and quality checks. Thinking is on by default and can be disabled per call.

Chat uses the embedded Jinja template, `/apply-template` and `/tokenize` for prompt admission, `/props?model=chat` for effective slot size, and an SSE `/v1/chat/completions` stream. Zinc assembles complete tool arguments before Eval, bounds response bytes during transfer, and reports HTTP status and phase diagnostics without recording prompts. It emits an empty message when each assistant model turn completes; the Connector then sends that turn without live edits, even when tool execution continues. Connector passes Discord PNG, JPEG, and WebP attachments through a bounded image envelope; images are not stored for later turns. Reranking uses the locked BGE GGUF. Model origin and endpoint paths remain trusted settings in `package/zinc.md`.

Models remain external to release archives. `models.ini` identifies their Hugging Face repositories and files; the
router resolves them through the standard Hugging Face cache. Build Cygnet data with:

```sh
lua tools/cygnet_index.lua SOURCE.db data/cygnet.db SOURCE_SHA256
```

## Agent Connector

The tracked `ac.yaml` defines the Zinc policy. Fill a member, channel, or guild route, then connect and run:

```sh
llama-server --models-preset models.ini --port 8000
agc connect .
agc check .
agc run .
```

Connector expands the configured actor, supplies the optional Discord Import, delivers each completed assistant turn, and
passes per-command config overlays without interpreting Zinc's schema. Zinc owns continuation in its Store. PA discovers pure Lua modules in the package Image and native modules under `package/native`. No Lua loader environment variables are needed. The PA binary and native module must both use ABI-compatible dynamic Lua 5.5.

## Development

```sh
python3 tools/format_fences.py
lx --lua-version 5.5 fmt --backend stylua --path package/src
CFLAGS=-DSQLITE_ENABLE_FTS5 lx --lua-version 5.5 build --only-deps
agent check package zinc
```

`agent check package` checks tracked source syntax; CI's Package step assembles and checks the complete `dist/zinc/` release from Lux's locked dependencies. `lx generate-rockspec` describes the future Lux source rock, not the self-contained PA bundle. The latter needs the locked Lua dependency sources and an ABI-compatible SQLite module under `package/native/`. For a local metadata-only comparison against the running model router after running the CI packaging commands locally:

```sh
python3 tools/measure_local.py --agent PATH/agent --package dist/zinc/package --cygnet dist/zinc/data/cygnet.db --output PROFILE.jsonl --compare
```

Zinc requires Portable Agents protocol 1 with `pa.emit(bytes, "append")`, `pa.log`, and bounded streaming `pa.http`. Connector and Zinc CI must pin the matched PA revision before publication.

License: AGPL-3.0-only.
