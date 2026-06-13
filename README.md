# Zinc

Zinc runs `.circuitry.yaml` systems.

It materializes Circuitry documents into stored normalized facts, plans from the database, executes ready parts, stores payloads as blobs, and exposes run state through `zinc://` URIs.

## CLI

```bash
zn run <shape> [name=value ...]
zn read <uri-or-file>
zn inspect <uri-or-file>
zn pkg install <source-or-name>
zn pkg remove <name>
zn pkg list
zn pkg check <name>
zn config
zn update --check
zn update
```

## Run

```bash
zn run examples/compute-math.circuitry.yaml principal=1000 rate=0.05 years=10
```

Zinc prints outputs and a run URI.

```bash
zn inspect zinc://runs/<run_id>
zn read 'zinc://runs/<run_id>/values/amount'
```

`zn update` shows staged progress for target resolution, download, checksum verification, preparation, and install.

## Runtime

A part is ready when every value in its local `takes` is available. Zinc runs needed parts only. Runtime defaults live in Zinc config.

```yaml
runtime:
  parallel: true
  max_parallel: 2
```

Graph-level `zinc.runtime` can override those settings for a single Circuitry document. `max_parallel: 0` uses the host CPU count.

Inline parts can execute deterministic arithmetic assignment lines. Model-backed parts use configured model presets. Shape parts can point to local files or package assets.

## Configuration

Zinc reads `.zinc/config.yaml` and `~/.zinc/config.yaml`.

```yaml
packages:
  responses: openai-responses@0.1.8

models:
  default: local-llama

  local-llama:
    adapter: responses.adapter
    params:
      endpoint: http://127.0.0.1:30000
      endpoint_kind: chat_completions
      model: local-gemma-4-e4b-it
      temperature: 0.2
```

## Packages

A package manifest has a navigable asset tree. Each leaf asset is any file in the package.

```yaml
name: openai-responses
version: "0.1.8"
about: OpenAI Responses-shaped model adapter package.

assets:
  adapter:
    path: adapters/responses.py
  shapes:
    short_answer:
      path: shapes/short-answer.circuitry.yaml
  prompts:
    runtime:
      path: prompts/runtime.md
  config:
    default:
      path: config/zinc.models.yaml
  docs:
    readme:
      path: docs/README.md
  icon:
    path: assets/icon.svg
```

Authored YAML uses `alias.path.to.asset` references.

```yaml
zinc:
  packages:
    responses: openai-responses@0.1.8

uses:
  answer:
    shape: responses.shapes.short_answer
```

```yaml
models:
  local-llama:
    adapter: responses.adapter
```

Packages may declare `soft_dependencies`; Zinc reports them during inspect/install and resolves them only when a reference uses them.

## Building

Zinc is written in Zig 0.16.0.

```bash
zig build
zig build test
```

## Learn more

- [Wiki](https://github.com/darkhorseprojects/zinc/wiki)
