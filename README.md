# Zinc

[![release](https://img.shields.io/github/v/release/darkhorseprojects/zinc?include_prereleases&label=release)](https://github.com/darkhorseprojects/zinc/releases)
[![license](https://img.shields.io/badge/license-Apache--2.0-blue)](#license)
[![zig](https://img.shields.io/badge/zig-0.16-orange)](https://ziglang.org/)

Zinc is a tiny Circuitry-native runtime for local coding agents.

```text
Circuitry graph -> Zinc loop plan -> semantic session log -> OpenAI/tool loop -> local llama.cpp server
```

Circuitry owns YAML, imports, validation, and graph normalization. Zinc consumes resolved Circuitry JSON bundles and handles the local runtime: config, packages, context, tools, compaction, and model serving.

## Primary contracts

- Circuitry graphs are source programs: `resources:`, `args:`, `imports:`.
- `circuitry parse graph.circuitry.yaml` is Zinc's graph loader boundary.
- `zn compile` compiles loop entrypoint graphs.
- `zn compact` owns compaction graphs.
- Packages install graphs, prompts, and assets without becoming part of Zinc itself.

## Install

```bash
npm install -g @darkhorseprojects/circuitry@0.3.10
./scripts/install-linux.sh
```

Installs:

```text
~/.local/bin/zn
~/.local/share/zinc/graphs/*.circuitry.yaml
~/.local/share/zinc/prompts/*.md
~/.config/zinc/config.yaml
```

The installer preserves an existing config file.

## Commands

```bash
zn "prompt"
zn run [--graph id|path] [--input name=value] [--text name=value|@file] [--file name=path] [--image name=path] [--session id|--continue] "prompt"

zn check [graph]
zn compile [graph] [plan.json]
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

## Graphs

A Zinc loop graph is a Circuitry graph with runtime args and a tool-using agent.

```yaml
circuitry: "0.3.10"
title: Repair loop
args:
  user_turn:
    type: text
    required: true
runtime:
  provider: zinc
  model: inherit
resources:
  user_turn:
    type: text
    value: ""

  assistant:
    type: agent
    identity: Zinc
    inputs: [user_turn]
    tools: [read, write, edit, bash]
    expect:
      response: str
    instructions: |
      Be direct. Use tools when useful.
```

Runtime inputs overlay declared resources for one run:

```bash
zn run --graph repair \
  --text notes=@notes.md \
  --file spec=./SPEC.md \
  --image screenshot=./shot.png \
  "fix this"
```

If the graph declares a text arg named `user_turn`, the positional prompt binds to it.

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

Install sources:

```bash
zn pkg add ./local-package
zn pkg add github:user/repo
zn pkg add github:user/repo/path/to/package
zn pkg add github:user/repo#v1.0.0
zn pkg add https://github.com/user/repo.git#<commit>
zn pkg add git+https://github.com/user/repo.git#<commit>
```

Local packages live in `.zinc/packages`. Global packages live in `~/.local/share/zinc/packages`. Local packages override global packages.

`zn pkg update <name>` reinstalls from the recorded source. If the source is pinned with `#tag` or `#commit`, the update remains pinned.

`zn update` updates every installed package, then updates Zinc itself and reruns the installer.

## Runtime model

```text
load config
resolve graph
compile loop plan
assemble session context
call provider
execute graph-declared tools
append semantic JSONL rows
compact when context pressure crosses threshold
```

Sessions are stored as semantic JSONL in `.zinc/sessions`. Tool calls and results replay as provider messages when a session continues.

## Config

Config precedence:

```text
.zinc/config.yaml
~/.config/zinc/config.yaml
built-in defaults
```

Common keys:

```yaml
paths:
  graph: ~/.local/share/zinc/graphs/zinc-loop.circuitry.yaml
  compiled_plan: ~/.local/share/zinc/compiled/plan.json
  compaction_graph: ~/.local/share/zinc/graphs/zinc-compaction.circuitry.yaml

provider:
  base_url: http://127.0.0.1:30000/v1
  authorization: Bearer zinc

runtime:
  max_retries: 5
  compaction_threshold_percent: 70
```

Inspect a value:

```bash
zn config get provider.base_url
```

## llama.cpp server

`zn serve` owns the local model server lifecycle. It clones/builds llama.cpp under `~/.local/share/zinc/llama.cpp`, downloads model artifacts under `~/.local/share/zinc/models`, and starts `llama-server` for the configured model.

```bash
zn serve
zn status
zn stop
```

## Development

```bash
zig build test
zig build
zig-out/bin/zn check
zig-out/bin/zn compile
```

## License

Apache-2.0. See [`LICENSE`](LICENSE).