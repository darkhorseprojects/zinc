# Zinc

[![release](https://img.shields.io/github/v/release/darkhorseprojects/zinc?color=64748b&style=flat-square)](https://github.com/darkhorseprojects/zinc/releases)
[![build](https://img.shields.io/github/actions/workflow/status/darkhorseprojects/zinc/release.yml?label=build&style=flat-square)](https://github.com/darkhorseprojects/zinc/actions)
[![license](https://img.shields.io/github/license/darkhorseprojects/zinc?color=333333&style=flat-square)](https://github.com/darkhorseprojects/zinc/blob/main/LICENSE)

Zinc is a small local runtime for Circuitry 0.5 graphs.

Circuitry defines YAML-native graph topology. Zinc supplies local effects: model calls, tools, sessions, runtime URIs, packages, permissions, and model serving.

```bash
zn "inspect this repo"
```

## Install

```bash
./scripts/install-linux.sh
```

Installs:

```text
~/.local/bin/zn
~/.local/share/zinc/graphs/*.circuitry.yaml
~/.local/share/zinc/prompts/*.md
~/.config/zinc/config.yaml
```

## CLI

```bash
zn "prompt"
zn run [graph|--graph id|path] [--export name] [--input name=value] [--text name=value|@file] [--file name=path] [--image name=path] [--session id|--continue] "prompt"
zn check [graph]
zn compact [--dry-run] [--session id|--continue] [graph]
zn graph list
zn graph show <graph>
zn config get <path>
zn pkg list
zn pkg add [--local|--global] [--replace] [--yes] <source>
zn pkg remove [--local|--global] [--yes] <name>
zn pkg update [--local|--global] [--yes] <name|--all>
zn pkg show [--local|--global] <name>
zn pkg exec <package> <script>
zn pkg attach <package>
zn pkg detach <package>
zn pkg attachments
zn serve [model]
zn doctor
zn stop
```

## Stock loop

```yaml
circuitry: "0.5"
title: Zinc loop

exports:
  main:
    run: assistant
    input:
      user_turn: string

resources:
  bash_guide:
    text:
      uri: prompt:bash-guide

  assistant:
    model:
      identity: Zinc
      input:
        - $user_turn
        - bash_guide
      tools:
        - read
        - write
        - edit
        - bash
        - run_graph
      schema:
        response: string
```

## Runtime boundary

Zinc materializes these Circuitry resource kinds:

- `text`
- `data`
- `file`
- `run`
- `model`

Circuitry owns validation, imports, exports, addresses, reachable input discovery, dependency planning, and schemas. Zinc executes effects only.

## Runtime URI schemes

Prompts:

```text
prompt:<id>
```

Inputs:

```text
input:<id>
```

Sessions:

```text
session:current
session:compaction
sessions:index
sessions:dir
session:current:messages:<index>
session:current:tools:<tool-call-id>
```

Byte ranges:

```text
<readable-uri>:bytes=<start>-<end>
```

## Tools

Zinc only exposes tools declared by the active `model` resource.

```yaml
resources:
  assistant:
    model:
      tools: [read, write, edit, bash, run_graph, hello_process]
```

Builtin Zinc tools:

- `read`
- `write`
- `edit`
- `bash`
- `run_graph`

Package tools are model-callable schemas backed by Zinc-owned handlers:

- `graph`
- `process`
- `http`
- `mcp`

Package scripts are operator commands run with `zn pkg exec`; they are not exposed to the model.

## Safety

Zinc is a local runtime. When the active graph declares tools, Zinc can read files, write files, edit files, run shell commands, and run other graphs. Only run graphs and packages you trust.

## Sessions and compaction

Zinc stores sessions as JSONL under `.zinc/sessions`. Compaction runs through the configured stock compaction graph when the replay context crosses the configured threshold.

## Packages

A Zinc package is a runtime/ecosystem convention, not Circuitry core. Packages can provide graphs, prompts, files, tools, scripts, and attach options while their graphs remain Circuitry source files.

## License

Apache-2.0
