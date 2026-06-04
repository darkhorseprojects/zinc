# Zinc

[![release](https://img.shields.io/github/v/release/darkhorseprojects/zinc?color=64748b&style=flat-square)](https://github.com/darkhorseprojects/zinc/releases)
[![build](https://img.shields.io/github/actions/workflow/status/darkhorseprojects/zinc/release.yml?label=build&style=flat-square)](https://github.com/darkhorseprojects/zinc/actions)
[![license](https://img.shields.io/github/license/darkhorseprojects/zinc?color=333333&style=flat-square)](https://github.com/darkhorseprojects/zinc/blob/main/LICENSE)

Zinc is a small runtime for Circuitry 0.5 graphs over OpenAI-compatible chat completion endpoints.

Circuitry defines YAML-native graph topology. Zinc supplies runtime effects: endpoint model calls, tools, sessions, runtime URIs, packages, and permissions.

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
6. Add a model endpoint to your config.
7. Run `zn doctor`.

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
zn [--default] [--model id] "prompt"
zn run [--default] [--model id] [graph|--graph id|path] [--export name] [--input name=value] [--text name=value|@file] [--file name=path] [--image name=path] [--session id|--continue] "prompt"
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
zn doctor
```

## Stock loop

`zinc-loop` is the normal assistant graph. It includes Zinc's built-in tools and can be extended by attached packages.

Use `--default` to run the stock graph without package extensions:

```bash
zn --default "answer without package extensions"
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

Zinc speaks OpenAI-compatible Chat Completions. Run any local or remote endpoint that exposes `/v1/chat/completions`, then point Zinc at it.

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

  hosted:
    model: provider/model-name
    base_url: https://example.com/v1
    api_key_env: PROVIDER_API_KEY
    context_window: 128000
    chars_per_token: 4
    temperature: 0.3
    reasoning:
      enabled: false
      effort: low
```

`context_window` is a model fact supplied by the user. Zinc uses it with `runtime.compaction_threshold_percent` to decide when to compact. If the endpoint does not return prompt usage, Zinc estimates prompt tokens with `chars_per_token`; the default `4` matches the usual English-text rule of thumb.

Select the normal model with `default_model`, override one run with `--model <id>`, or attach a configured model to a specific Zinc `model` resource with `using:`:

```yaml
resources:
  assistant:
    model:
      using: local
      identity: Zinc
      input:
        - $user_turn
      instructions: Answer directly.
```

The stock config does not include a model. For local GGUF/Hugging Face models, run `llama-server`, vLLM, LM Studio, Ollama's OpenAI-compatible endpoint, or another compatible endpoint yourself, then add that endpoint to your Zinc config. Zinc does not download model files, build inference engines, or manage server processes.

Zinc normalizes trailing slashes so `/v1/chat/completions` is not doubled. `zn doctor` reports the selected model id, base URL, model name, context window, `api_key_env` name, whether the env var is present, and whether the endpoint is reachable. If no model is configured, it reports that instead of assuming one. It never prints secret values.

## Tools

Zinc only exposes tools declared by the active `model` resource. Attached packages can extend `zinc-loop`; `--default` bypasses those package extensions and runs the stock graph.

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

Handlers are `process`, `http`, or `mcp`. Use the built-in `run_graph` tool for graph execution. Package scripts are operator commands run with `zn pkg exec`; they are not exposed to the model.

## Safety

Zinc is a local runtime. When the active graph declares tools, Zinc can read files, write files, edit files, run shell commands, call package handlers, and run graphs through `run_graph`. Only run graphs and packages you trust.

## Sessions and compaction

Zinc stores sessions as JSONL under `.zinc/sessions`; that is an internal storage detail, not a user-authored format. Compaction runs through the configured stock compaction graph when the replay context crosses `runtime.compaction_threshold_percent` of the active model's configured `context_window`.

## Packages

A Zinc package is a runtime/ecosystem convention, not Circuitry core. Packages are YAML-native and can provide graphs, prompts, files, tools, scripts, and attach options while their graphs remain Circuitry source files. Package attach state is graph-native in `.zinc/graphs/zinc-extensions.circuitry.yaml`.

## License

Apache-2.0
