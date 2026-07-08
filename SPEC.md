# Zinc Specification

Zinc is a replaceable local host around Circuitry turns.

## Boundaries

```text
Circuitry = source entries, source processes, KDL in/out, and stepping
Zinc      = packets, threads, context building, editable turn, bundled web lifecycle, observation
```

Source entries use `in`/`out` templates to declare input requirements and output bindings. Object `in` serializes to KDL on stdin; string `in` sends raw bytes with `$`/`@` refs substituted inline. Captured stdout is coerced (JSON, then whichever of KDL/YAML the text's shape actually matches, else raw text).

If a source process needs execution or more information, it returns `circuitry`; Zinc records it, advances it through Circuitry, builds new context, and continues.

Configured Circuitry runs as the current OS user. The only host-level interception is a policy gate on the configured `$shell`: returned-circuitry calls whose source resolves to `$shell` have their command head checked against `allowlist` before spawning. Every other source — the turn's own declared sources, HTTP endpoints, nested Circuitry documents — passes through untouched.

## Packet, Thread, Context

```text
Packet  = immutable byte record
Thread  = stored conversation made from packet ranges
Context = prepared loop input built from a Thread
```

Internal code represents a Thread as `ThreadBody`:

```text
ranges     ordered packet byte ranges
packet     packet id
from/to    optional byte bounds
```

Internal code represents editable Thread text as `ThreadText`:

```text
mdx        editable text
ranges     text ranges mapped back to packet byte ranges
byteLength byte count
```

`Context` is not an object in code. It is the string passed to Circuitry as `state.context`.

Editing a thread's mdx (autosave, or a turn appending its response) stores the entire new text as one new immutable packet and rewrites the thread body to a single range pointing at it. Older packets stay in the store, unreferenced by the current body, but never mutated.

## Install

`bin/install.js` manages package installation and default runtime setup:

- checks Bun is installed
- installs root and web dependencies
- builds and copies the bundled web app
- installs the `zn` executable

No Python, no virtual environment, no shebang rewriting.

## Zinc home

Default homes:

```text
Linux:   ${XDG_CONFIG_HOME:-~/.config}/zinc
macOS:   ~/Library/Application Support/Zinc
Windows: %APPDATA%\Zinc
```

Project-local `zn here` uses `./.zinc`.

```text
config.kdl
zinc.db
stores.jsonl
turn.md
```

## Config

```kdl
store "~/.config/zinc/zinc.db"
turn "~/.config/zinc/turn.md"
zinc-dir "~/.config/zinc"
raw-context-bytes 8192
packet-overflow-bytes 65536
completions-url "https://api.openai.com/v1/chat/completions"
shell "sh"
allowlist { git ls grep }
```

## Store schema

```sql
create table meta (key text primary key, value text not null);
create table packets (id text primary key, parent text, at integer not null, bytes blob not null);
create table threads (id text primary key, title text, body text not null, updated integer not null);
```

`schema_version` in `meta` is `1`. The store engine is `@tursodatabase/database` everywhere — the CLI, the web server, and any tooling that opens a store file all use the same driver.

Packet rows normally store exact packet bytes. If a packet exceeds `packet-overflow-bytes`, Zinc writes the exact bytes to an OS temp file and stores an overflow marker in `packets.bytes`. The marker contains the file path, original byte size, and tail bytes. `zn packet read` and web store reads resolve the marker and return the exact original packet bytes.

## Known stores

`stores.jsonl` beside the config is a flat, append-only list of `{"path","name"}` lines — not a database, just the set of store files the CLI and web UI know about. `zn stores` lists it; the web UI's store switcher reads/writes it via `/api/stores`.

## Continuation

1. Zinc appends the latest user packet.
2. Zinc updates the thread body.
3. Zinc builds context from the Thread: raw tail (most recent `raw-context-bytes` of packet text), sequential head packet refs formatted as `- packet_id` or `- packet_id from:to`, and Fibonacci-spaced middle packet refs between them. Raw sections contain only packet text, not packet metadata.
4. Zinc seeds Circuitry state with `context`, `completions`, `shell`, and `cwd`.
5. Zinc calls Circuitry `advance()` on `turn.md`.
6. Zinc records each advanced source entry without copying full source input into the transcript.
7. Only the last terminal binding from the *last* entry advanced in a step decides the outcome: `response` ends the continuation and becomes the assistant packet; `circuitry` is advanced and the turn continues with new context; `reasoning` records an interim packet and loops again. The `out {}` declaration order is irrelevant.

## Default turn

The default turn's one real source entry is `respond source="$completions"` — Circuitry's built-in HTTP/SSE support, not a script. It streams `content`/`reasoning_content` from a standard chat-completions response and binds `response`/`reasoning`. There is no default source process for shell execution either: the model returns circuitry naming `$shell` directly (`run source="$shell" "-c" "cmd"`), and Circuitry spawns it like any other executable.

## CLI

```bash
zn init [--config PATH]
zn here
zn up
zn down
zn logs [--lines N]
zn status
zn stores
zn packet read --packet PACKET [--config PATH]
zn thread list [--config PATH]
zn thread read --thread THREAD [--config PATH]
zn clean [--global] [--all]
```

`zn init` and `zn here` initialize store/config/home. They do not install anything.

`zn up`, `zn down`, `zn logs`, and `zn status` manage the bundled Zinc web app for the active config using `web.pid` and `web.log`.
