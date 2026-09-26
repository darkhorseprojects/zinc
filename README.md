# Zinc

Zinc is a [Portable Agents](https://github.com/darkhorseprojects/portable-agents) package for conversations that need durable, searchable memory and tightly configured tools. It combines actor-scoped history, chronological and semantic retrieval, Lua-based tool calls, and temporary nested agents in one package. It runs against a configured local model endpoint; it is not a hosted model or a general-purpose agent framework.

## What it does

- **Carries memory across calls.** Each actor continues from their stored history, with explicit branch coordinates available when you need controlled context.
- **Finds relevant past details.** Chronological history and Cygnet-backed semantic retrieval provide bounded context to the model.
- **Keeps tools configured.** Presets define the actual Lua capabilities and their grants. The `safe` preset means configured access, not a universal security guarantee; review its roots, endpoints, and permissions.
- **Supports nested investigations.** A tool can start a temporary Zinc branch with a more restrictive preset, inspect its result, then discard it.
- **Bounds tool work.** Per-run quotas meter accepted tool source and results; separate limits constrain model rounds, tool sizes, retrieval, and requests.

See the [Zinc wiki](https://github.com/darkhorseprojects/zinc/wiki) for the package's configuration and memory model.

## Use it

Build Zinc as a Portable Agents package, then invoke the `zinc` entry with UTF-8 question bytes and JSON configuration. Minimal configuration:

```json
{"version":1,"actor":"account:42","preset":"safe"}
```

`actor` is the authenticated identity that owns the durable history. Select `unsafe`, `safe`, or `no-host` as the preset. Optional `parent` and `memory` values select an explicit branch; run, model, and retrieval settings can also be overridden within trusted defaults.

The package entry is `package/zinc.md`. The tracked Connector policy in `ac.yaml` demonstrates how to pass actor identity and grants to Zinc. For a local run, start the compatible model server and then:

```sh
agc connect .
agc check .
agc run .
```

The default model configuration expects the Prism llama.cpp build pinned in `models.lock`, with the configured chat and rerank models available through its Hugging Face cache. Model weights are not included in the repository or release archives. Build and runtime requirements, including the matched Portable Agents revision and Lua 5.5 ABI, are documented below and in the [wiki](https://github.com/darkhorseprojects/zinc/wiki).

## Package and development

- `package/` contains the tracked Portable Agents source and presets.
- `models.ini` configures the chat and rerank model aliases.
- `data/cygnet.db` is the semantic retrieval index.
- Release packaging assembles the package and its locked Lua dependencies; model weights remain external.

Development and packaging commands:

```sh
python3 tools/format_fences.py
lx --lua-version 5.5 fmt --backend stylua --path package/src
CFLAGS=-DSQLITE_ENABLE_FTS5 lx --lua-version 5.5 build --only-deps
agent check package zinc
```

A complete release also needs an ABI-compatible dynamic Lua 5.5 runtime. Zinc requires Portable Agents protocol 1, including append-mode streaming and bounded HTTP support. Connector and Zinc must use a matched Portable Agents revision.

## Learn more

- [Zinc wiki](https://github.com/darkhorseprojects/zinc/wiki) — configuration, presets, memory, retrieval, quota, and model setup
- [Portable Agents](https://github.com/darkhorseprojects/portable-agents) — package runtime and embedding API
- [Agent Connector](https://github.com/darkhorseprojects/agent-connector) — Discord integration and policy configuration

License: [AGPL-3.0-only](LICENSE).
