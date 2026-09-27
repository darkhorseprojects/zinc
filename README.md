# Zinc

Zinc is a [Portable Agents](https://github.com/darkhorseprojects/portable-agents) package for conversations that need
durable, searchable memory and tightly configured tools. It combines actor-scoped history, chronological and semantic
retrieval, Lua tool calls, and temporary nested agents. It uses a configured local model endpoint; it is not a hosted
model or a general-purpose agent framework.

## What it does

- **Carries memory across calls.** Each actor continues from stored history. Explicit branch coordinates provide
  controlled context when needed.
- **Finds relevant past details.** Chronological history and Cygnet-backed semantic retrieval provide bounded model
  context.
- **Keeps tools configured.** Presets define Lua capabilities and grants. The `safe` preset means configured access, not
  a universal security guarantee; review its roots, endpoints, and permissions.
- **Supports nested investigations.** A tool can start a temporary Zinc branch with a more restrictive preset, inspect
  its result, then discard it.
- **Bounds tool work.** Per-run quotas meter accepted tool source and results. Separate limits constrain model rounds,
  tool sizes, retrieval, and requests.

See the [Zinc wiki](https://github.com/darkhorseprojects/zinc/wiki) for the configuration and memory model.

## Install

Install Portable Agents and Agent Connector independently, with both `agent` and `agc` available on `PATH`. Install an
architecture-compatible Lua 5.5 shared library that the operating system's dynamic loader can find.

Download the Zinc archive for the machine running `agent`, extract it, and run Zinc's installer:

```sh
./install.sh
```

On Windows:

```powershell
.\install.ps1
```

The default installation directories are:

| Platform | Directory                                             |
| -------- | ----------------------------------------------------- |
| Linux    | `${XDG_DATA_HOME:-$HOME/.local/share}/zinc`           |
| macOS    | `$HOME/Library/Application Support/Zinc`              |
| Windows  | `%LOCALAPPDATA%\Zinc`                                 |

Pass a destination as the first shell argument or as `-Destination` in PowerShell to install elsewhere. Reinstalling
replaces Zinc's managed package and retrieval data while preserving `ac.yaml`, `models.ini`, and `state/`.

The installer copies only Zinc. Release archives contain no `agent`, `agc`, Lua runtime, model server, or model weights.

## Connect

The installed `ac.yaml` contains a Zinc policy. Start the configured model server, then use the installation directory
with Agent Connector:

```sh
agc connect /path/to/zinc
agc check /path/to/zinc
agc run /path/to/zinc
```

Minimal Zinc configuration is:

```json
{"version":1,"actor":"account:42","preset":"safe"}
```

`actor` is the authenticated identity that owns the durable history. Select `unsafe`, `safe`, or `no-host` as the preset.
Optional `parent` and `memory` values select an explicit branch. Trusted callers can also override allowed run, model,
and retrieval settings.

The package entry is `package/zinc.md`. The tracked Connector policy demonstrates actor identity and grants. The default
model configuration expects the Prism llama.cpp build pinned in `models.lock`, with its chat and rerank models available
through the Hugging Face cache. Model weights are not included.

## Runtime contract

Zinc uses Portable Agents protocol 1, including append-mode process streaming and bounded HTTP responses. Compatibility
is determined by the protocol, package format, required capabilities, and Lua 5.5 ABI—not matching repository commits or
release numbers.

The platform-native SQLite module and `agent` must load an ABI-compatible Lua 5.5 runtime from the same provider. Release
modules request `liblua5.5.so.0` on Linux, `@rpath/liblua.5.5.dylib` on macOS, and `lua55.dll` on Windows. `PATH` locates
`agent` and `agc`; the operating system's dynamic loader locates Lua.

## Development

- `package/` contains the Portable Agents source and presets.
- `models.ini` configures chat and rerank aliases.
- `data/cygnet.db` is generated from the locked Cygnet source during packaging.
- `lux.lock` pins Zinc's Lua package dependencies.

Build and validation commands:

```sh
python3 tools/format_fences.py
lx --lua-version 5.5 fmt --backend stylua --path package/src
CFLAGS=-DSQLITE_ENABLE_FTS5 lx --lua-version 5.5 build --only-deps
agent check package zinc
```

Development and release builds use a provider-neutral system Lua 5.5 installation. The six release jobs build the native
SQLite module on its target architecture, install Zinc into a clean destination, and validate it with independently
released `agc` and `agent` fixtures.

## Learn more

- [Zinc wiki](https://github.com/darkhorseprojects/zinc/wiki) — configuration, presets, memory, retrieval, quotas, and
  model setup
- [Portable Agents](https://github.com/darkhorseprojects/portable-agents) — package runtime and embedding API
- [Agent Connector](https://github.com/darkhorseprojects/agent-connector) — Discord integration and policy routing

License: [AGPL-3.0-only](LICENSE).
