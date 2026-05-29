# Zinc

[![release](https://img.shields.io/github/v/release/darkhorseprojects/zinc?include_prereleases&label=release)](https://github.com/darkhorseprojects/zinc/releases)
[![license](https://img.shields.io/badge/license-Apache--2.0-blue)](#license)
[![zig](https://img.shields.io/badge/zig-0.16-orange)](https://ziglang.org/)

Zinc is a tiny local runtime for Circuitry 0.4 graphs.

Circuitry stores executable topology. Zinc supplies the body: local model loop, tools, sessions, prompt resolution, packages, compaction, and model serving.

```text
Circuitry resource graph -> Zinc entry plan -> OpenAI-compatible tool loop -> semantic session log
```

## Boundary

- Prompts are inputs.
- Tools are runtime functions.
- Graphs are executable topology.
- Zinc resolves and runs a Circuitry entry resource.

Zinc targets the resource-native Circuitry 0.4 contract. It expects graphs with `entry`, `inputs`, prompt resources via `uri: prompt:<id>`, and declarative `type: run` resources.

## Install

```bash
npm install -g @darkhorseprojects/circuitry@^0.4.2
./scripts/install-linux.sh
```

Installs:

```text
~/.local/bin/zn
~/.local/share/zinc/graphs/*.circuitry.yaml
~/.local/share/zinc/prompts/*.md
~/.config/zinc/config.yaml
```

## Commands

```bash
zn "prompt"
zn run [--graph id|path] [--entry id] [--input name=value] [--text name=value|@file] [--file name=path] [--image name=path] [--session id|--continue] "prompt"

zn check [graph]
zn compile [graph] [plan.json] [--entry id]
zn compact [--dry-run] [--session id|--continue] [graph]
zn update [--ref tag-or-commit] [--skip-packages] [--skip-zinc]

zn graph list
zn session-dir
zn config get <path>

zn pkg add [--local|--global] [--replace] <source>
zn pkg list
zn pkg show [--local|--global] <name>
zn pkg update [--local|--global] <name>
zn pkg remove [--local|--global] <name>

zn serve [model]
zn status
zn stop
```

## Graph shape

```yaml
circuitry: "0.4"
title: Repair loop
entry: assistant
inputs:
  user_turn:
    type: text
    required: true
resources:
  user_turn:
    type: input
    from: user_turn

  bash_guide:
    type: text
    uri: prompt:bash-guide

  assistant:
    type: agent
    identity: Zinc
    inputs: [user_turn, bash_guide]
    tools: [read, write, edit, bash, run_graph]
    expect:
      response: str
    instructions: |
      Be direct. Use tools when useful.
```

Declarative graph run resources let one graph depend on the result of another graph:

```yaml
resources:
  recovered_context:
    type: run
    graph: ./context-recovery.circuitry.yaml
    entry: focused_recovery
    inputs:
      user_turn: user_turn
      session_log: session_log

  assistant:
    type: agent
    inputs: [user_turn, recovered_context]
```

Dynamic graph runs go through the `run_graph` tool.

## Packages

A package is a directory with `zinc.pkg.yaml` and exported assets.

```yaml
name: browser-repair
version: 0.1.0
description: Browser repair graphs and prompts.

exports:
  graphs:
    repair: graphs/repair.circuitry.yaml
  prompts:
    dom-debug: prompts/dom-debug.md
  assets:
    screenshot: assets/example.png
```

Local packages live in `.zinc/packages`. Global packages live in `~/.local/share/zinc/packages`. Local packages override global packages.

## Runtime model

```text
load config
resolve graph
select entry
compile Zinc entry plan
assemble session context
call provider
execute graph-declared tools
append semantic JSONL rows
compact when context pressure crosses threshold
```

Sessions are stored as semantic JSONL in `.zinc/sessions`. Tool calls and results replay as provider messages when a session continues.

## Development

```bash
zig build test
zig build
zig-out/bin/zn check
zig-out/bin/zn compile
```

## License

Apache-2.0. See [`LICENSE`](LICENSE).
