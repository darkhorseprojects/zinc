[![Release](https://badgen.net/badge/Release/success/green?icon=github)](https://github.com/darkhorseprojects/zinc/actions/workflows/release.yml)
[![License](https://badgen.net/github/license/darkhorseprojects/zinc?label=License&color=black&icon=github)](LICENSE)

# Zinc

Zinc is a replaceable local host for Circuitry turns.

Circuitry is the document/source-process contract. Zinc stores packets and threads, builds context for the configured turn, streams source-process output, and records each advance.

```text
Packet  = immutable byte record
Thread  = stored conversation made from packet ranges
Context = prepared loop input built from a Thread
```

## Install

Bun/TypeScript throughout. No Python runtime, no virtual environment, no dependency install step for the turn itself.

```bash
bun bin/install.js
```

It installs root and web dependencies, builds the web app, installs `zn`, and copies the built assets into `~/.local/lib/zinc`.

## Editable Zinc home

`zn init` creates a user-editable Zinc home and store/config:

```text
Linux:   ${XDG_CONFIG_HOME:-~/.config}/zinc
macOS:   ~/Library/Application Support/Zinc
Windows: %APPDATA%\Zinc
```

Layout:

```text
config.kdl
zinc.db
stores.jsonl
turn.md
```

`zn here` creates project-local store/config in `./.zinc/`.

## Config

```kdl
store "/path/to/zinc.db"
turn "/path/to/turn.md"
zinc-dir "/path/to/zinc-home"
raw-context-bytes 8192
packet-overflow-bytes 65536
completions-url "https://api.openai.com/v1/chat/completions"
shell "sh"

allowlist {
  git
  ls
  grep
}
```

`shell` is the executable seeded into the turn as `$shell` (default `sh`, `pwsh` on Windows). `allowlist` gates only calls to `$shell` via returned circuitry — nested blocks flatten to permitted command heads; empty/absent permits everything. `packet-overflow-bytes`: packets larger than this limit are stored outside the store database; the DB row keeps a tail and a pointer. `raw-context-bytes`: byte budget for raw tail content and head packet refs in assembled context.

`zn up`, `zn down`, `zn logs`, and `zn status` manage the bundled Zinc web app. Runtime state lives beside the config as `web.pid` and `web.log`. `stores.jsonl` beside the config tracks known store files (path + name), not a database.

## Turn

```kdl
respond source="$completions" {
  in "{\"messages\": [{\"role\": \"system\", \"content\": \"@Instructions\"}, {\"role\": \"user\", \"content\": \"$context\"}]}"
  out "{\"choices\": [{\"message\": {\"content\": \"?response\", \"reasoning_content\": \"?reasoning\"}}]}"
}

out { reasoning ?reasoning; response ?response; circuitry ?circuitry }
```

`$completions` is Circuitry's built-in HTTP/SSE source support — no sidecar script. Only the last terminal binding from the *last* entry advanced in a step decides the outcome: `response` ends the turn, `circuitry` is returned Circuitry that Zinc records, advances, and continues from; reasoning-only steps keep looping. The `out {}` declaration order does not matter.

## Boundaries

Configured Circuitry runs as the current OS user. Source processes read their own config. OS permissions decide what they can access. The only host-level interception is the shell allowlist described above; everything else Circuitry names, Zinc runs.

## CLI

```bash
zn init
zn here
zn up
zn down
zn logs [--lines 200]
zn status
zn stores
zn packet read --packet pkt_...
zn thread list
zn thread read --thread thr_...
```
