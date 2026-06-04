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

Install from the latest release. The installers copy `zn`, stock graphs, stock prompts, and the default config for the platform.

| Platform | Release asset | Installer |
| --- | --- | --- |
| Linux x86_64 | `zinc-linux-x86_64.tar.gz` | `scripts/install-unix.sh` |
| macOS Apple Silicon | `zinc-macos-aarch64.tar.gz` | `scripts/install-unix.sh` |
| macOS Intel | `zinc-macos-x86_64.tar.gz` | `scripts/install-unix.sh` |
| Windows x86_64 | `zinc-windows-x86_64.zip` | `scripts/install-windows.ps1` |

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
4. Copy `stock/graphs` and `stock/prompts` into the platform data directory below.
5. Copy `stock/config.yaml` into the platform config path if no config exists yet.
6. Run `zn doctor`.

Zinc keeps platform paths behind its layout layer:

```text
Linux config:   $XDG_CONFIG_HOME/zinc/config.yaml or ~/.config/zinc/config.yaml
Linux data:     $XDG_DATA_HOME/zinc or ~/.local/share/zinc
Linux state:    ~/.local/state/zinc
macOS config:   ~/Library/Application Support/zinc/config.yaml
macOS data:     ~/Library/Application Support/zinc
macOS state:    ~/Library/Application Support/zinc/State
Windows config: %APPDATA%\zinc\config.yaml
Windows data:   %APPDATA%\zinc
Windows state:  %LOCALAPPDATA%\zinc\State
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

The default `zinc-loop` graph is a lean chat loop with session memory. It does not attach tool schemas to ordinary turns.

```yaml
circuitry: "0.5"
title: Zinc loop

exports:
  main:
    run: assistant
    input:
      user_turn: string
      recovered_context: string

resources:
  assistant:
    model:
      identity: Zinc
      input:
        - $user_turn
        - $recovered_context
```

Use `zinc-agent` for explicit file, shell, package, or graph tool work:

```bash
zn run zinc-agent "inspect this repo"
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

## Models

Model configuration is Zinc runtime config. Circuitry graphs do not contain provider settings.

Zinc supports two runtime model kinds:

- `local`: Zinc-managed `llama.cpp`, with weights downloaded from Hugging Face.
- `openai`: an external OpenAI-compatible endpoint.

```yaml
default_model: qwen-heretic-mtp

models:
  qwen-heretic-mtp:
    kind: local
    model: qwen3.6-27b-heretic-mtp-q3_k_s
    base_url: http://127.0.0.1:30000/v1
    llama_cpp:
      engine: llama.cpp
      repo: https://github.com/ggml-org/llama.cpp.git
      ref: master
    hf:
      repo: owner/model-repo
      file: model.gguf

  openrouter-gpt:
    kind: openai
    model: openai/gpt-4.1-mini
    base_url: https://openrouter.ai/api/v1
    api_key_env: OPENROUTER_API_KEY

  vllm-coder:
    kind: openai
    model: Qwen/Qwen2.5-Coder-7B-Instruct
    base_url: http://127.0.0.1:8000/v1
```

`kind: local` is only for Zinc-managed `llama.cpp` served from Hugging Face model files. `kind: openai` is only for non-local OpenAI-compatible HTTP endpoints. Zinc normalizes trailing slashes so `/v1/chat/completions` is not doubled.

`zn doctor` reports the selected model id, kind, base URL, served model name, `api_key_env` name, and whether the env var is present. It never prints secret values and does not make paid API calls.

## Tools

The default `zinc-loop` graph is lean chat + session memory. It does not attach tools to every turn, so ordinary prompts stay fast.

Use `zinc-agent` when you explicitly want file, shell, package, or graph tools:

```bash
zn run zinc-agent "inspect this repo"
```

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

Package tools use YAML-native input schemas and primary-key handlers:

```yaml
tools:
  hello_process:
    description: Run the packaged hello process tool.
    input:
      name: string
      loud:
        optional: boolean
    docs:
      name: Name to greet
      loud: Whether to shout
    handler:
      process:
        command:
          linux: tools/hello-process
          macos: tools/hello-process
          windows: tools/hello-process.cmd
```

Handlers are `graph`, `process`, `http`, or `mcp`. Package scripts are operator commands run with `zn pkg exec`; they are not exposed to the model.

## Safety

Zinc is a local runtime. When the active graph declares tools, Zinc can read files, write files, edit files, run shell commands, and run other graphs. Only run graphs and packages you trust.

## Sessions and compaction

Zinc stores sessions as JSONL under `.zinc/sessions`; that is an internal storage detail, not a user-authored format. Compaction runs through the configured stock compaction graph when the replay context crosses the configured threshold.

## Packages

A Zinc package is a runtime/ecosystem convention, not Circuitry core. Packages are YAML-native and can provide graphs, prompts, files, tools, scripts, and attach options while their graphs remain Circuitry source files. Package attach state is graph-native in `.zinc/graphs/zinc-extensions.circuitry.yaml`.

## License

Apache-2.0
