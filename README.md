# Zinc

[![release](https://img.shields.io/github/v/release/darkhorseprojects/zinc?color=64748b&style=flat-square)](https://github.com/darkhorseprojects/zinc/releases)
[![build](https://img.shields.io/github/actions/workflow/status/darkhorseprojects/zinc/release.yml?label=build&style=flat-square)](https://github.com/darkhorseprojects/zinc/actions)
[![license](https://img.shields.io/github/license/darkhorseprojects/zinc?color=333333&style=flat-square)](https://github.com/darkhorseprojects/zinc/blob/main/LICENSE)

[**Circuitry**](https://github.com/darkhorseprojects/circuitry) &nbsp;•&nbsp; [**Specification**](https://github.com/darkhorseprojects/circuitry/blob/main/SPEC.md) &nbsp;•&nbsp; [**Packages**](#packages) &nbsp;•&nbsp; [**Runtime boundary**](#runtime-boundary)

Zinc is a tiny local runtime for Circuitry graphs.

Circuitry defines topology. Zinc supplies the local effects: model calls, tools, sessions, runtime URIs, packages, and model serving.

```bash
zn "inspect this repo"
```

## The idea

A Circuitry graph is a durable source file. Zinc makes it executable on your machine.

- `input`, `text`, and `data` resources become concrete values.
- `agent` resources run through the configured local provider.
- `run` resources execute child graphs through the same resolver.
- tools are Zinc runtime effects explicitly declared by the active Circuitry resource.

Zinc does not own nodes, edges, compiled plans, imports, or graph validation. Circuitry owns topology and contracts. Zinc materializes resources and supplies effects.

## Why it matters

A local coding agent should be small enough to inspect and direct.

Zinc keeps the loop plain:

```text
prompt → Circuitry entry → resource resolver → agent loop → local tools → session log
```

The session is a JSONL log. The default loop is a Circuitry graph. Prompt packs are files. Large bash output is kept out of context and pointed to by path. Graph execution asks before dynamic runs.

## Install

Install Circuitry first, then Zinc:

```bash
npm install -g @darkhorseprojects/circuitry@^0.4.5
./scripts/install-linux.sh
```

Installs:

```text
~/.local/bin/zn
~/.local/share/zinc/graphs/*.circuitry.yaml
~/.local/share/zinc/prompts/*.md
~/.config/zinc/config.yaml
```

The config file is installed with user-only permissions.

Zinc is local-first. Model selection is config-driven under `default_model` and `models.*`. To swap models, point a model entry at another compatible local/HF/GGUF file set, set `default_model`, then run the local llama.cpp serve flow:

```bash
zn serve
zn doctor
```

`zn serve` reads the same config, builds/uses llama.cpp, downloads missing HF/GGUF files when configured, and serves the selected model locally.

First useful commands:

```bash
zn "hello"
zn graph list
zn run zinc-loop "hello"
```

## CLI

```bash
zn "prompt"
zn run [graph|--graph id|path] [--entry id] [--input name=value] [--text name=value|@file] [--file name=path] [--image name=path] [--session id|--continue] "prompt"

zn check [graph]
zn compact [--dry-run] [--session id|--continue] [graph]
zn clean [--local|--global] [--yes] [sessions | logs | packages | state | all]

zn graph list
zn graph show <graph>
zn session-dir
zn config get <path>

zn pkg list
zn pkg add [--local|--global] [--replace] [--yes] <source>
zn pkg remove [--local|--global] [--yes] <name>
zn pkg update [--local|--global] [--yes] <name|--all>
zn pkg show [--local|--global] <name>

zn update [--ref tag-or-commit]
zn serve [model]
zn doctor
zn stop
```

## Core graph

The stock loop is just a Circuitry graph:

```yaml
circuitry: "0.4"
title: "Zinc default loop"
entry: assistant
inputs:
  user_turn:
    type: text
    required: true
resources:
  user_turn:
    type: input
    from: user_turn

  recovered_context:
    type: text
    uri: session:compact-context

  bash_guide:
    type: text
    uri: prompt:bash-guide

  circuitry_author:
    type: text
    uri: prompt:circuitry-author

  assistant:
    type: agent
    identity: Zinc
    inputs: [user_turn, recovered_context, bash_guide, circuitry_author]
    tools: [read, write, edit, bash, run_graph]
```

## Runtime boundary

Circuitry defines topology. Zinc supplies effects.

Zinc resolves these resource types:

- `input`
- `text`
- `data`
- `run`
- `agent`

Zinc also provides runtime URI schemes.

### Prompts

`prompt:<id>`

### Inputs

`input:<id>`

### Sessions

`session:current`
`sessions:index`
`sessions:dir`

### Session objects

`session:current:messages:<index>`
`session:current:tools:<tool-call-id>`
`session:compact-context`

### Byte ranges

`<readable-uri>:bytes=<start>-<end>`

## Tool policy

Zinc only exposes tools declared by the active Circuitry resource.

```yaml
resources:
  assistant:
    type: agent
    tools: [read, write, edit, bash, run_graph]
```

If `bash` is not declared, the agent does not get `bash`. If `run_graph` is not declared, the agent cannot request graph runs.

Circuitry decides which tools a graph may request.
Zinc decides how those tools behave locally.

Minimal local behavior config:

```yaml
scope: project

tools:
  bash: build
  graph_runs: ask

confirm_commands:
  - rm
  - sudo
  - chmod
```

`scope` is `readonly`, `project`, or `open`. The default `project` scope keeps Zinc-controlled file tools and bash in the current project/workdir where Zinc can cheaply recognize paths. This is not a sandbox.

`tools.bash` is `inspect`, `build`, or `open`. `inspect` allows code-defined inspection command heads and asks for configured confirmations. `build` allows commands except configured confirmations. `open` allows all shell commands.

Builtin Zinc tools:

- `read`: read a file or Zinc runtime URI.
- `write`: create or overwrite a UTF-8 file.
- `edit`: replace exact text in a UTF-8 file.
- `bash`: run a shell command in the current working directory.
- `run_graph`: request execution of a Circuitry graph through Zinc policy.

## Safety note

Zinc is a local runtime. When the active graph declares tools, Zinc can read files, write files, edit files, run shell commands, and run other graphs. Only run graphs and packages you trust, especially in sensitive directories.

## Graph run approval

`type: run` is declarative graph topology.

`run_graph` is dynamic runtime capability. With the default policy:

```yaml
tools:
  graph_runs: ask
```

Zinc prints the graph, entry, reason, risk, and inputs, then asks:

```text
Approve? [y/N]
```

Approving runs the graph through Zinc's normal child-graph resolver. Denying stops that graph run. Agent bash cannot bypass this by invoking `zn run`; direct user CLI usage of `zn run` still works.

## Sessions and compaction

Zinc stores sessions as JSONL under `.zinc/sessions`.

Context is rendered from the session log with configurable head/tail windows and per-message truncation. If rendered context crosses the configured threshold, Zinc compacts between turns using the stock compaction graph.

Large bash output is summarized in the model context. Full output is written to a temp file and referenced by exact path.

## Packages

A Zinc package is a runtime/ecosystem convention, not Circuitry core. Packages can export graphs, prompts, and assets while the Circuitry graphs remain portable graph files.

A Zinc package is a directory with `zinc.pkg.yaml` and exported graphs, prompts, and assets.

```yaml
name: browser-repair
version: "0.1.0"
exports:
  graphs:
    repair: graphs/repair.circuitry.yaml
  prompts:
    dom-debug: prompts/dom-debug.md
  assets:
    screenshot: assets/example.png
```

Packages can be local project packages or global user packages. The repository includes `examples/packages/hello`:

```bash
zn pkg add --local examples/packages/hello
zn graph list
zn run hello "Ada"
```

The hello package exports one graph and one prompt.

## License

Apache-2.0
