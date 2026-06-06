# Zinc

[![release](https://img.shields.io/github/v/release/darkhorseprojects/zinc?color=64748b&style=flat-square)](https://github.com/darkhorseprojects/zinc/releases)
[![build](https://img.shields.io/github/actions/workflow/status/darkhorseprojects/zinc/release.yml?label=build&style=flat-square)](https://github.com/darkhorseprojects/zinc/actions)
[![license](https://img.shields.io/github/license/darkhorseprojects/zinc?color=333333&style=flat-square)](https://github.com/darkhorseprojects/zinc/blob/main/LICENSE)

Zinc is a small runtime for Circuitry graphs over OpenAI-compatible chat completion endpoints.

Circuitry describes graph topology. Zinc supplies runtime effects: model endpoint calls, tools, packages, sessions, runtime URIs, config, permissions, and local project layout.

```bash
zn "inspect this repo"
```

## Install

Linux and macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/darkhorseprojects/zinc/main/scripts/install-unix.sh | sh
```

Windows PowerShell:

```powershell
iwr https://raw.githubusercontent.com/darkhorseprojects/zinc/main/scripts/install-windows.ps1 -OutFile install-zinc.ps1
.\install-zinc.ps1
```

Manual install:

1. Download the asset for your platform from <https://github.com/darkhorseprojects/zinc/releases/latest>.
2. Extract it.
3. Put `zn` or `zn.exe` on `PATH`.
4. Copy `stock/graphs` and `stock/prompts` into the platform data directory.
5. Copy `stock/config.yaml` into the platform config path if no config exists yet.
6. Add a model endpoint to your config.
7. Run `zn doctor`.

## Configure a model

Zinc is endpoint-only. It does not bundle a model, download model files, build inference engines, or start a default server.

Add an OpenAI-compatible endpoint to Zinc config:

```yaml
default_model: local

models:
  local:
    model: model-name-served-by-your-endpoint
    base_url: http://127.0.0.1:30000/v1
    api_key_env:
    context_window: 8192
    chars_per_token: 4
    temperature: 0.7
    reasoning:
      enabled: false
      effort: low
```

Config paths:

| Platform | Config |
| --- | --- |
| Linux | `$XDG_CONFIG_HOME/zinc/config.yaml` or `~/.config/zinc/config.yaml` |
| macOS | `~/Library/Application Support/zinc/config.yaml` |
| Windows | `%APPDATA%\zinc\config.yaml` |

## CLI

```bash
zn [--default] [--model id] "prompt"
zn run [--default] [--model id] [graph|--graph id|path] [--export name] [--input name=value] [--text name=value|@file] [--file name=path] [--image name=path] [--session id|--continue] "prompt"
zn check [graph]
zn compact [--dry-run] [--session id|--continue] [graph]
zn graph list
zn graph show <graph>
zn config get <path>
zn clean [--local|--global] [--yes] [sessions | logs | packages | generated | config | runtime | all]
zn pkg list
zn pkg add [--local|--global] [--replace] [--yes] [--model id] <source>
zn pkg remove [--local|--global] [--yes] [--model id] <name>
zn pkg update [--local|--global] [--yes] <name|--all>
zn pkg show [--local|--global] <name>
zn pkg exec <package> <script>
zn pkg call <tool> <json-arguments>
zn doctor
```

## Local project layout

A project may have a local `.zinc/` workspace:

```text
.zinc/graphs/                         project graphs
.zinc/generated/                      Zinc-written wiring
.zinc/packages/<name>/                installed package code and assets
.zinc/config/packages/<name>.yaml     user/project package config
.zinc/runtime/packages/<name>/        package working runtime
.zinc/sessions/                       conversation transcripts
.zinc/logs/                           runtime logs
.zinc/tmp/                            short-lived temporary files
```

The important split is simple: package code goes in `packages`, user choices go in `config`, package working files go in `runtime`, and generated wiring goes in `generated`.

## Packages

Install a package from a GitHub subdirectory:

```bash
zn pkg add --local github:owner/repo/packages/example#v1.0.0
```

A package can provide prompts, files, graphs, scripts, and external tools. Local package installs patch `.zinc/graphs/zinc-loop.circuitry.yaml` and write generated package resources to `.zinc/generated/packages.circuitry.yaml`.

Official optional packages live in [`darkhorseprojects/zinc-packages`](https://github.com/darkhorseprojects/zinc-packages). They are not installed by default.

Package tools use external handlers: `process`, `http`, or `mcp`. Graph execution stays built into Zinc through `run_graph`.

## Wiki

The project wiki is the canonical long-form reference:

- [Home](https://github.com/darkhorseprojects/zinc/wiki)
- [Architecture](https://github.com/darkhorseprojects/zinc/wiki/Architecture)
- [Project Layout](https://github.com/darkhorseprojects/zinc/wiki/Project-Layout)
- [Configuration](https://github.com/darkhorseprojects/zinc/wiki/Configuration)
- [Graphs](https://github.com/darkhorseprojects/zinc/wiki/Graphs)
- [Runtime](https://github.com/darkhorseprojects/zinc/wiki/Runtime)
- [Tools](https://github.com/darkhorseprojects/zinc/wiki/Tools)
- [Packages](https://github.com/darkhorseprojects/zinc/wiki/Packages)
- [Sessions](https://github.com/darkhorseprojects/zinc/wiki/Sessions)

## Safety

Zinc is a local runtime. When the active graph declares tools, Zinc can read files, write files, edit files, run shell commands, call package handlers, and run graphs through `run_graph`.

Only run graphs and packages you trust.

## License

Apache-2.0
