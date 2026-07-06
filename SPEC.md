# Zinc Specification

Zinc is a replaceable local host around Circuitry turns.

## Boundaries

```text
Circuitry = source entries, source processes, KDL input/output, and stepping
Zinc      = packets, threads, context building, editable agent files, bundled web lifecycle, observation
```

If a source process needs execution or more information, it returns `circuitry`; Zinc records it, advances it through Circuitry, builds new context, and continues.

Configured Circuitry runs as the current OS user.

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

## Install

`bin/install.py` manages package installation and default runtime setup:

- checks required programs
- builds and copies the bundled web app
- installs the `zn` executable
- copies default editable agent templates
- creates `agent/.venv`
- installs `agent/requirements.txt`
- rewrites default `.py` shebangs to the venv Python

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
agent/
  turn.md
  openai-responses.py
  openai-responses.kdl
  shell.py
  requirements.txt
  .venv/
```

## Config

```kdl
store "~/.config/zinc/zinc.db"
turn "~/.config/zinc/agent/turn.md"
zinc-dir "~/.config/zinc"
agent-dir "~/.config/zinc/agent"
python "~/.config/zinc/agent/.venv/bin/python"
raw-context-bytes 8192
packet-overflow-bytes 65536
```

## Store schema

```sql
create table meta (key text primary key, value text not null);
create table packets (id text primary key, parent text, at integer not null, bytes blob not null);
create table threads (id text primary key, title text, body text not null, updated integer not null);
```

`schema_version` in `meta` is `1`.

Packet rows normally store exact packet bytes. If a packet exceeds `packet-overflow-bytes`, Zinc writes the exact bytes to an OS temp file and stores an overflow marker in `packets.bytes`. The marker contains the file path, original byte size, and tail bytes. `zn packet read` and web store reads resolve the marker and return the exact original packet bytes.

## Continuation

1. Zinc appends the latest user packet.
2. Zinc updates the thread body.
3. Zinc builds context from the Thread: raw tail (most recent `raw-context-bytes` of packet text), sequential head packet refs up to `raw-context-bytes`, and Fibonacci-spaced middle packet refs between them.
4. Zinc seeds Circuitry state with `context`, `cwd`, `store`, `loop-dir`, and `python`.
5. Zinc calls Circuitry `advance()` on `turn.md`.
6. Zinc records each advanced source entry without copying full source input into the transcript.
7. `response` ends the continuation and becomes the assistant packet.
8. `circuitry` is recorded, parsed, advanced, recorded, and then the turn continues with new context.

## Default source processes

`openai-responses.py` reads KDL stdin, calls the OpenAI Responses API, and writes KDL stdout containing `reasoning`, `response`, and/or `circuitry`.

`shell.py` reads `cmd` and `cwd`, runs a platform shell, and writes `output`, `stderr`, `code`, and `shell`. Command nonzero exit code is data, not source-process failure.

## CLI

```bash
zn init [--home DIR] [--store PATH] [--config PATH]
zn here
zn up
zn down
zn logs [--lines N]
zn status
zn packet read --store STORE --packet PACKET [--range START:END]
zn thread list --store STORE
zn thread read --store STORE --thread THREAD
```

`zn init` and `zn here` initialize store/config/home. They do not install Python dependencies.

`zn up`, `zn down`, `zn logs`, and `zn status` manage the bundled Zinc web app for the active config using `web.pid` and `web.log`.
