# Zinc

Zinc runs `.circuitry.yaml` systems.

It builds a lazy plan from `$` value wiring, executes ready parts, stores typed values, and exposes run state through `zinc://` URIs.

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

A part is ready when every value in its local `takes` is available. Zinc runs needed parts only. With `runtime.parallel` enabled, Zinc runs bounded ready waves concurrently and commits results in plan order.

```yaml
zinc:
  runtime:
    parallel: true
    max_parallel: 2
```

`max_parallel: 0` uses the host CPU count.

Inline parts can execute deterministic arithmetic assignment lines. Model-backed parts use configured model presets. Shape parts can point to local files or package assets.

## Configuration

Zinc reads `.zinc/config.yaml` and `~/.zinc/config.yaml`.

```yaml
packages:
  responses: openai-responses@0.1.5

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

A package manifest has one asset namespace. Assets declare what they do.

```yaml
name: openai-responses
version: "0.1.5"
about: OpenAI Responses-shaped model adapter package.

assets:
  short-answer:
    path: shapes/short-answer.circuitry.yaml
    does: circuitry.shape

  responses:
    path: adapters/responses.py
    does:
      - zinc.adapter
      - openai.responses
```

Authored YAML uses compact `alias.asset` references. Zinc determines the required asset capability from context.

```yaml
zinc:
  packages:
    responses: openai-responses@0.1.5

uses:
  answer:
    shape: responses.short-answer
```

```yaml
models:
  local-llama:
    adapter: responses.responses
```

Packages may declare `soft_dependencies`; Zinc reports them during inspect/install, never installs them automatically, and fails only when a missing optional asset is used.

## Building

Zinc is written in Zig 0.16.0.

```bash
zig build
zig build test
```

## Wiki

https://github.com/darkhorseprojects/zinc/wiki
