# Zinc

Zinc is a compact Portable Agents package with optional durable history, exact model token accounting, Cygnet retrieval, and parallel generated Lua tools.

## Run

Start the pinned llama.cpp router, then:

```sh
printf 'Explain the current package.' | agent run \
  --directory . --entry zinc.md \
  --lua-memory 96MiB --process-memory 512MiB --wall-time 2m \
  -- local:example
```

`config.store = false` is temporary. A package-relative path enables durable SQLite history. `max_stored_record_bytes` retains a valid UTF-8 suffix of oversized records.

## Modules

Trusted implementation uses `zinc.internal.*`. Generated code sees the sealed public modules:

```text
pa.document
pa.env
pa.host
zinc.design
zinc.history
```

Generated Lua uses normal `require` and can inspect `package.loaded`:

```lua
local host = require("pa.host")
local history = require("zinc.history")
return history.available() and history.around(42) or host.files.read({ path = "README.md" })
```

`zinc.design.guide` describes how to build another agent. Guides are optional for public modules.

## Models and retrieval

Chat models provide `/v1/chat/completions`, `/apply-template`, and `/tokenize`; rerankers provide `/v1/rerank` and `/tokenize`. Zinc renders the actual template and tool schema, tokenizes it exactly, and gives generation the remaining context. Model limits live in each model record.

Durable retrieval combines independent chronological and semantic token windows. Semantic candidates come from actor-scoped FTS, the self-contained Cygnet database, and reranking. Retrieved records and tool output are untrusted data.

```sh
/tmp/lux-install-042/bin/lx test
lua tools/benchmark.lua
```

License: AGPL-3.0-only.
