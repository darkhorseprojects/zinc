![Zinc](artwork.svg)

# Zinc

Zinc is a persistent local agent packaged for [Portable Agents](https://github.com/darkhorseprojects/portable-agents). Portable Agents remains the runtime and authority boundary; Zinc adds durable actor-isolated history, retrieval, llama.cpp orchestration, generated Markdown execution, and delegated file, HTTP, and shell operations.

## Architecture

```text
request
  │
  ├─ Store tail ── Qwen3 Embedding ── dense candidates
  │                                      │
  │                               Qwen3 Reranker
  │                                      │
  │                         hops + neighbors + provenance
  │                                      │
  └──────────────────────────── LiquidAI LFM2.5-2.6B
                                         │
                                run_lua / answer
                                         │
                                  Portable Agents
                                         │
                               Store append + final text
```

A Run retrieves Memory once from its actor-visible snapshot. The active transcript then only appends. Store history is scanned newest-first under `store_bytes`; rendered retrieval is packed under `context_bytes`. Child Runs are merged or discarded explicitly. The local `store` directory resolves portably to `~/.agents/zinc/store/`.

Zinc wraps `run_lua` source in a Portable Agents document for execution. It supplies configured file operations, HTTP origins, shell headers, child Runs, Builder operations, and read-only anchored Memory navigation.

## Models

Provision the exact revisions in [`dependencies.lock`](dependencies.lock). Three `llama-server` services are required:

| port | model | placement |
| --- | --- | --- |
| 8000 | `LiquidAI/LFM2.5-2.6B-GGUF` | CPU/GPU chat completions |
| 8001 | `Qwen/Qwen3-Embedding-0.6B` | CPU/GPU embeddings (`/v1/embeddings`) |
| 8002 | `Qwen/Qwen3-Reranker-0.6B` | CPU/GPU reranking (`/v1/rerank`) |

The build and launch commands are in [`dev/llama.cpp`](dev/llama.cpp). Start embedding and reranking before the agent so `llama-server` sizes memory appropriately. Zinc does not start or supervise these processes.

```sh
dev/llama.cpp/embed
dev/llama.cpp/rerank
dev/llama.cpp/agent
dev/llama.cpp/health
```

## Configure

Edit [`zinc.md`](zinc.md) for endpoints and the three Memory policies:

- `store_bytes`: maximum historical Store JSON scanned backward from the tail;
- `context_bytes`: maximum retrieved Memory JSON supplied to a Run;
- `hops`: maximum bridge-query rounds.

Edit [`env.md`](env.md) to grant directory access, HTTP origins, and shell headers.

## Run

```sh
agent check --directory . --entry zinc.md

printf 'Inspect this workspace.' | agent run \
  --directory . --entry zinc.md \
  --authority src/store.lua \
  --authority src/memory.lua \
  --authority src/llamacpp.lua \
  --authority src/env.lua \
  -- discord-user-42
```

Only the final normal message is printed. Reasoning, generated source, tool results, and child history remain in the Store.

## Validate

```sh
for suite in store memory llamacpp run environment builder format_discord integration concurrency; do
  python3 "test/$suite.py"
done

LLAMACPP_REAL=1 python3 test/lfm.py
LLAMACPP_REAL=1 python3 test/lfm_children.py
python3 bench/memory.py
```

The real-model tests are opt-in. They test model behavior rather than only HTTP compatibility and can expose nondeterministic model failures.

## License

[Apache-2.0](LICENSE)
