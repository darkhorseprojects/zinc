# Zinc

Zinc is a compact Portable Agents package with optional durable history, exact model token accounting, and Cygnet retrieval. Model calls and generated Lua tools run sequentially.

## Run

Start the pinned llama.cpp router, then run:

```sh
printf 'Explain the current package.' | agent run \
  --directory . --entry zinc.md --lua-memory 96MiB -- local:example
```

Set `config.memory.store` to `false` for temporary execution or to a SQLite path for durable history. `max_stored_record_bytes` keeps a valid UTF-8 suffix when a record is oversized.

## Modules

Trusted runtime code is collapsed into `zinc.internal.model`, `zinc.internal.memory`, and `zinc.internal.run`. Generated code can require the sealed public modules:

```text
pa.markdown
pa.env
pa.host
zinc.design
zinc.history
```

`zinc.history` is bound to the current actor and request. Generated code cannot select another actor. Nested `ask` calls and model turns have explicit limits.

## Models and retrieval

Chat models provide `/v1/chat/completions`, `/apply-template`, and `/tokenize`. Rerankers provide `/v1/rerank` and `/tokenize`. Zinc renders and tokenizes the actual prompt before assigning the remaining context to generation.

HTTP requests are blocking and bounded. Zinc parses complete bounded SSE responses, requires `[DONE]`, validates tool fragments, and executes tool calls in model order. Tool chunks must return exactly one non-`nil` portable value.

Durable retrieval combines a chronological token window with older semantic candidates. SQLite FTS grounds terms, Cygnet expands concepts, and the reranker orders bounded candidates. Retrieved records and tool output remain untrusted data.

```sh
lx test
lua tools/benchmark.lua
agent check --directory . --entry zinc.md --lua-memory 96MiB
```

Handwritten runtime source under `src/**/*.lua` is limited to 549 nonblank lines. Markdown, tests, tools, vendor code, and generated data are excluded.

License: AGPL-3.0-only.
