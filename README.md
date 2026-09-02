# Zinc

Zinc is a compact Portable Agents package with durable actor-isolated history, exact model token accounting, Cygnet retrieval, and sequential generated Lua tools.

## Run

Start the pinned llama.cpp router, then run without Zinc-level limits:

```sh
printf 'Explain the current package.' | agent run \
  --directory . --entry zinc.md --lua-memory 96MiB -- local:example
```

An optional strict JSON object in `argv[2]` supplies output, model-call, tool, SSE-event, HTTP, record, and retrieval budgets. Missing fields are unbounded at Zinc’s layer. A supplied `maximum_model_calls` counter is shared by root turns and nested `zinc.history.ask` calls.

For Discord, Zinc ships `agent-connector.yaml` with a complete recommended policy and explicit runtime budgets but no Discord IDs. Run `agc connect .` to enter the token, derive bot/application IDs, store the token separately, and print the invite link. Route IDs remain operator-owned.

## Modules and capabilities

Trusted runtime code remains four Lua files: public `zinc.history` plus private `zinc.internal.model`, `zinc.internal.memory`, and `zinc.internal.run`. `host.md` owns file, model-origin, inspection-process, shell, cwd, and per-process environment authority. There are no `ZINC_*` or `PA_*` configuration variables.

After PA seals the package, Zinc injects a deterministic basic capability list into every root and nested prompt. It lists public module guides and concrete host roots, origins, canonical programs, argv templates, cwd, and child environment names. Generated code can inspect sealed `package.loaded` and use real `require`. Mounted capabilities such as Discord appear generically; Zinc contains no Discord-specific behavior or secrets.

`zinc.history` is bound to the current actor and request. Generated code cannot select another actor. Compile, Lua, capability usage, return-shape, UTF-8, and encoding failures become failed tool results so the model can correct them. Model protocol, database, budget, and Agent failures remain terminal.

## Models and retrieval

Chat models provide `/v1/chat/completions`, `/apply-template`, and `/tokenize`. Rerankers provide `/v1/rerank` and `/tokenize`. Zinc validates dense tokenizer arrays, prompt context, bounded or unbounded SSE, `[DONE]`, finish reasons, dense tool indices, unique nonempty IDs, and no data after completion.

Durable records commit before completion events. Optional record truncation retains a valid UTF-8 suffix. Retrieval independently applies chronological row/token, semantic token/term, grounding, exact-form, and candidate limits when supplied. SQLite statements finalize on success and failure, every query remains actor/start-bound, and reranking is sequential.

```sh
lx test
lua tools/benchmark.lua
agent check --directory . --entry zinc.md --lua-memory 96MiB
```

Handwritten runtime source under `src/**/*.lua` is limited to 566 nonblank lines. Markdown, tests, tools, vendor code, and generated data are excluded.

License: AGPL-3.0-only.
