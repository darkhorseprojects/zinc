# Zinc

Zinc is a local Portable Agents package with durable conversational results and bounded semantic retrieval. It runs as one disposable process and one Lua state per request. Every completed user item, assistant response, and tool result is committed to package-local SQLite before Zinc exposes its record ID.

## Storage and retrieval

Zinc creates `store/zinc.db` beneath `package.directory` on first use. One database holds all actors, but actor-qualified rows and FTS queries prevent cross-actor reads. Record IDs remain globally chronological.

Recent records and semantic matches have separate byte budgets. Zinc grounds literal SQLite FTS terms, expands concepts directly through Cygnet, excludes records already in the chronological window, and sends one bounded candidate set to the reranker. Cygnet uses immutable `data/cygnet.db` and a deterministic `data/cygnet-index.db` sidecar.

Generated Lua receives only invocation-local `results` and the capabilities mounted for the request:

```lua
local results = require("results")
results.read(id)
results.around(id)
results.ask("durable nested request")
```

Generated code cannot load Zinc implementation modules or ambient Lua packages. Trusted Host code still runs with the invoking account's authority; its path, origin, process, and environment checks are policy boundaries rather than an operating-system sandbox.

## Dependencies

Moonstone 0.4.1 owns Lua 5.5, runtime modules, tests, lint, and Ballad packaging. `moonstone.toml` declares the environment and `moonstone.lock` records its resolved artifacts. `models.lock` pins Cygnet, model revisions, and model servers.

A Ballad distribution contains Zinc source, Cygnet data, and the Lua runtime modules Zinc imports. `src.dependencies` points trusted Lua loading at that package-local closure before any native module is opened. Zinc therefore does not depend on HOME, cwd, LuaRocks trees, or global Lua search paths at runtime.

Zinc supports only platforms where Moonstone, Lua 5.5, Portable Agents, and Zinc's native modules have passed together. Native Windows release qualification is still blocked; the project does not claim Windows support.

## Check and package

Build Portable Agents 1.0.0 in the sibling `../portable-agents` checkout, then run:

```sh
moon sync --locked
moon run format-check
moon run lint
moon run test
moon run benchmark
moon run agent-check
moon run release
moon run integration
```

Check the packaged directory without ambient Lua paths:

```sh
env -i HOME="$TMPDIR/zinc-home" PATH=/usr/bin:/bin \
  LUA_PATH='/missing/?.lua' LUA_CPATH='/missing/?.so' \
  ../portable-agents/zig-out/bin/agent check \
  --directory dist/zinc --entry zinc.md \
  --mount host=host.md --mount design=design.md \
  --trust src.cygnet --trust src.dependencies --trust src.host \
  --trust src.models --trust src.store --lua-memory 96MiB
```

Run from the source package or install it into Portable Agents' account store:

```sh
agent install dist/zinc --name zinc
cd ~/.agents/zinc
printf 'Inspect this workspace.' | agent run \
  --installed zinc --entry zinc.md \
  --mount host=host.md --mount design=design.md \
  --trust src.cygnet --trust src.dependencies --trust src.host \
  --trust src.models --trust src.store --lua-memory 96MiB -- "$USER"
```

The final argument is the stable actor ID. Output is strict NDJSON. The terminal event is `{ "type":"store", "result":N, "start":M }`; failed executions do not fabricate one.

Portable Agents has no internal deadline. The caller owns wall-clock and whole-process limits. Forced termination can skip finalizers and does not terminate descendants created by trusted code.

## Models

Chat uses `LiquidAI/LFM2.5-2.6B-GGUF` revision `b421ad1d549afeda6a0fb2ad3a697cb5a7879adc`. Reranking uses `nvidia/llama-nemotron-rerank-1b-v2` revision `d896ceda696c5c6fe0abf65f63a77c691bbf4548`. Zinc starts and downloads neither service. The LFM2.5 deployment needs `--override-kv lfm2.context_length=int:131072`.

See the [retrieval reference](https://github.com/darkhorseprojects/zinc/wiki/Retrieval) for scoring, traversal, exclusions, and packing rules.

## License

[Apache-2.0](LICENSE)
