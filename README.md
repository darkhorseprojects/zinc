# Zinc

Zinc is a small local runtime for Circuitry agent graphs.

It keeps the boundary sharp:

```text
Circuitry YAML -> resolved graph bundle -> Zinc loop plan -> local OpenAI-compatible agent loop
```

Circuitry owns YAML, imports, schema checks, and normalization. Zinc owns local config, packages, session context, tools, compaction, and the llama.cpp server lifecycle.

## Install

```bash
npm install -g @darkhorseprojects/circuitry@0.3.9
./scripts/install-linux.sh
```

The installer builds `zn`, installs stock graphs/prompts under `~/.local/share/zinc`, and creates `~/.config/zinc/config.yaml` if one does not already exist.

## Daily use

```bash
zn "explain this repo"
zn run --graph repair --text notes=@notes.md "fix the failing test"
zn compact
zn update
```

`zn update` updates installed Zinc packages, then updates Zinc from `https://github.com/darkhorseprojects/zinc.git` and reruns the installer. Use `--skip-packages` or `--skip-zinc` to update only one side.

## Commands

```bash
zn [--session id|--continue] <prompt>
zn run [--graph id|path] [--input name=value] [--text name=value|@file] [--file name=path] [--image name=path] [--session id|--continue] <prompt>

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

A Zinc loop graph is a Circuitry source graph with runtime args and at least one tool-using agent.

```yaml
circuitry: "0.3.2"
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

Runtime bindings:

```text
--input name=value   text literal
--text name=value    text literal
--text name=@file    text loaded from file
--file name=path     file input, readable as input:<name>
--image name=path    image input sent as model image content
```

If the graph declares a text arg named `user_turn`, the positional prompt binds to it.

## Packages

A package is a directory with `zinc.pkg.yaml` plus exported files.

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
```

Local packages install to `.zinc/packages`. Global packages install to `~/.local/share/zinc/packages`. Local packages win when names overlap.

## Config

Config precedence:

```text
.zinc/config.yaml
~/.config/zinc/config.yaml
built-in defaults
```

Useful keys:

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

## Runtime model

```text
load config and graph
compile graph to a loop plan
assemble semantic session context
call provider
execute graph-declared tools
append semantic JSONL rows
compact when context pressure is high
```

Sessions live in `.zinc/sessions`. Tool calls and results replay as conversation messages.

## Local model server

`zn serve` clones/builds llama.cpp under `~/.local/share/zinc/llama.cpp`, downloads model files under `~/.local/share/zinc/models`, and starts `llama-server` for the configured model.

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

TBD.
