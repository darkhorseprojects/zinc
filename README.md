# Zinc

Zinc is a local Portable Agents package with flat durable results, generated Lua tools, and long-term conversational
retrieval. It streams provisional model activity, commits every completed item independently, and emits durable record
IDs only after SQLite and FTS state commit.

## Execution

```text
request → durable user record → chronological + semantic context → streaming chat
                                                              │
                                                              └→ run_lua → registered capabilities

completed item → Store + FTS commit → completion event
unfinished item → absent
later failure → earlier completed records remain
```

`start` is the user-record ID that began one execution. Historical access is actor-isolated and requires `id < start`.
Generated Lua receives:

```lua
local results = require("results")
results.read(id)
results.around(id)
results.ask("durable nested request")
```

Nested requests are ordinary durable chronology. There are no execution trees, parent links, snapshots, statuses,
merge, discard, or compatibility schemas.

## Retrieval

Recent continuity and semantic recall use separate byte-bounded lanes of complete durable records. The detailed attention
formula, semantic traversal, exclusions, one-pass ranking, and packing rules are in the
[retrieval reference](https://github.com/darkhorseprojects/zinc/wiki/Retrieval).

## Models

Pinned reranking uses `nvidia/llama-nemotron-rerank-1b-v2` revision
`d896ceda696c5c6fe0abf65f63a77c691bbf4548`. Chat uses `LiquidAI/LFM2.5-2.6B-GGUF` revision
`b421ad1d549afeda6a0fb2ad3a697cb5a7879adc`. Chat streams; proposal and reranker requests are complete buffered JSON.
Zinc starts and downloads nothing.

The pinned LFM2.5 GGUF metadata is corrected at deployment with:

```text
--override-kv lfm2.context_length=int:131072
```

Pinned runtime data, model revisions, and toolchains are in [`dependencies.lock`](dependencies.lock). Lua module
versions are in [`zinc-dev-1.0-1.rockspec`](zinc-dev-1.0-1.rockspec) and [`luarocks.lock`](luarocks.lock); LuaSQLite3
0.9.7 is hash-verified and built against system SQLite. Licenses are in [`NOTICE`](NOTICE).

## Run

```sh
agent check --directory . --entry zinc.md \
  --mount host=host.md --mount design=design.md \
  --trust src.host --trust src.models --trust src.store \
  --lua-memory 96MiB --timeout 30s

printf 'Inspect this workspace.' | agent run \
  --directory . --entry zinc.md \
  --mount host=host.md --mount design=design.md \
  --trust src.host --trust src.models --trust src.store \
  --lua-memory 96MiB --timeout 30s -- "$USER"
```

The final argument is the stable actor ID. Canonical NDJSON events are provisional `reasoning`/`response` chunks,
durable completion IDs, durable tool calls/results, and terminal `{ "type":"store", "result":N, "start":M }`.
Failed executions emit no synthetic terminal event.

Each command starts one disposable `agent` process and one fresh Lua state. `--lua-memory` limits Lua allocator traffic
and separately bounds stdin length; it is not an RSS limit. `--timeout` is armed inside that process before package work
and hard-exits it with status 124 if Lua, a model request, native SQLite, or output blocks past the deadline. External
measurement also includes process startup and caller wake-up, so 30 seconds is a lower bound rather than an exact
end-to-end observation. Hard expiration skips finalizers and does not terminate descendants created by trusted code.

## Check

```sh
python tools/check.py
ZINC_MODELS=1 python tools/check.py --models
python tools/check_models.py
```

## License

[Apache-2.0](LICENSE)
