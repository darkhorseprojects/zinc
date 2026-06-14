# Zinc

Zinc runs `.circuitry.yaml` systems through package capabilities.

Circuitry owns the language layer: `takes`, `uses`, `does`, `gives`, bindings, composition, and diagnostics. Packages own integrations, tools, providers, shell behavior, OS behavior, and package config interpretation. Zinc coordinates package resolution, config loading, request formation, fragment memory, and assembly over Limbo.

## CLI

```bash
zn run <shape> [name=value ...]
zn read <uri-or-file>
zn inspect <uri-or-file>
zn pkg install <package-dir> [--global|--workspace]
zn pkg remove <name>
zn pkg list
zn pkg check <name>
zn pkg update <name|--all> [--check]
zn config
zn update --check
zn update
```

## Run

```bash
zn run examples/local-llama-answer.circuitry.yaml question="what is zinc?"
```

Execution is visible through the Limbo fragment fabric:

```bash
zn inspect zinc://packages
zn inspect zinc://fragments
zn inspect zinc://choices
zn inspect zinc://config
zn read zinc://fragments/<fragment>
zn read zinc://choices/<choice>
```

The core tables are intentionally small:

```text
packages(package, root)
fragments(fragment, target, request, result, time)
choices(choice, fragment)
config(key, value)
```

A fragment is completed work. Its identity is derived from the target, exact request bytes, and exact result bytes. A choice is mutable memory from target/request identity to the chosen fragment.

```text
choice   = hash(target + request)
fragment = hash(target + request + result)
```

`does` is instruction material passed to the selected capability. It is not shell text, arithmetic, or Zinc code.

## Configuration

Zinc reads `.zinc/config.yaml` and `~/.zinc/config.yaml`.

```yaml
models:
  default: local-llama

  local-llama:
    adapter: openai-responses.adapter
    params:
      endpoint: http://127.0.0.1:30000
      endpoint_kind: chat_completions
      model: local-gemma-4-e4b-it
      temperature: 0.2
```

Model profiles and adapter params stay in YAML. Package config remains in the package unless a human explicitly copies or references it.

## Packages

A package is an arbitrary self-contained directory with `zinc.pkg.yaml`. Zinc registers only the package root in Limbo and walks the manifest lazily; it does not catalog assets, scripts, dependencies, provider settings, or package internals into runtime tables.

```yaml
name: openai-responses
version: "0.2.0"
about: OpenAI Responses-shaped model adapter package.

source:
  git: https://github.com/darkhorseprojects/darkhorseprojects-packages.git
  ref: main
  path: openai-responses

adapter: adapters/responses.py

shapes:
  short_answer: shapes/short-answer.circuitry.yaml

config:
  models: config/zinc.models.yaml

setup:
  linux: scripts/setup
check:
  linux: scripts/check
remove:
  linux: scripts/remove
```

References are manifest paths:

```text
openai-responses.adapter
openai-responses.shapes.short_answer
openai-responses.config.models
```

Package systems integrate at their package boundary. Zinc does not absorb npm, Python, shell, PowerShell, provider, or OS-specific internals.

## Building

Zinc is written in Zig 0.16.0.

```bash
zig build
zig build test
```
