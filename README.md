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

The installer manages package files, the bundled web app, and the default Python source-process environment.

```bash
python3 bin/install.py
```

It installs `zn`, builds/copies the web app, copies editable agent templates, creates `agent/.venv`, installs `agent/requirements.txt`, and rewrites default `.py` shebangs to the venv Python.

## Editable Zinc home

`zn init` creates a user-editable Zinc home and store/config only:

```text
Linux:   ${XDG_CONFIG_HOME:-~/.config}/zinc
macOS:   ~/Library/Application Support/Zinc
Windows: %APPDATA%\Zinc
```

Layout:

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

`zn here` creates project-local store/config in `./.zinc/`.

## Config

```kdl
store "/path/to/zinc.db"
turn "/path/to/agent/turn.md"
zinc-dir "/path/to/zinc-home"
agent-dir "/path/to/zinc-home/agent"
python "/path/to/zinc-home/agent/.venv/bin/python"
raw-context-bytes 8192
packet-overflow-bytes 65536
```

`packet-overflow-bytes`: packets larger than this limit are stored outside the store database; the DB row keeps a tail and a pointer. `raw-context-bytes`: byte budget for raw tail content and head packet refs in assembled context.

`zn up`, `zn down`, `zn logs`, and `zn status` manage the bundled Zinc web app. Runtime state lives beside the config as `web.pid` and `web.log`.

## Agent files

The default Zinc agent directory is a Circuitry turn plus executable source processes.

```text
turn.md                 configured Circuitry turn
openai-responses.py     OpenAI Responses source process
openai-responses.kdl    adapter config
shell.py                optional shell source process
requirements.txt        Python deps installed by the installer
```

## Turn

```kdl
respond source="$python" {
  in {
    args "./openai-responses.py"
    stdin { context $context; cwd $cwd; store $store; loop-dir $loop-dir; instructions @Instructions }
  }
  out { reasoning ?reasoning; response ?response; circuitry ?circuitry }
}
```

`response` ends the turn. `circuitry` is returned Circuitry: Zinc records it, advances it, records the result, builds updated context, and continues.

## Boundaries

Configured Circuitry runs as the current OS user. Source processes read their own config. OS permissions decide what they can access.

The OpenAI adapter does not run shell commands. It only turns OpenAI Responses output into KDL stdout. Other source processes, including `shell.py`, are Circuitry entries.

## CLI

```bash
zn init
zn here
zn up
zn down
zn logs [--lines 200]
zn status
zn packet read --store /tmp/zinc.db --packet pkt_...
zn thread list --store /tmp/zinc.db
zn thread read --store /tmp/zinc.db --thread thr_...
```
