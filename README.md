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
zn inspect zinc://run/<run_id>
zn read 'zinc://run/<run_id>/value/$amount'
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
  responses: openai-responses@0.1.7

models:
  default: local-llama

  local-llama:
    adapter: responses.responses
    params:
      endpoint: http://127.0.0.1:30000
      endpoint_kind: chat_completions
      model: local-gemma-4-e4b-it
      temperature: 0.2
```

## Packages

A package manifest has one asset namespace. Each asset is a named path.

```yaml
name: openai-responses
version: "0.1.7"
about: OpenAI Responses-shaped model adapter package.

assets:
  short-answer: shapes/short-answer.circuitry.yaml
  responses: adapters/responses.py
  runtime-prompt: prompts/runtime.md
  default-config: config/zinc.models.yaml
  readme: docs/README.md
  icon: assets/icon.svg
```

Authored YAML uses compact `alias.asset` references.

```yaml
zinc:
  packages:
    responses: openai-responses@0.1.7

uses:
  answer:
    shape: responses.short-answer
```

```yaml
models:
  local-llama:
    adapter: responses.responses
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
