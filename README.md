# Zinc

Zinc is the host that runs Circuitry action systems.

Circuitry is YAML for action systems. Zinc loads `.circuitry.yaml`, confirms it through `circuitry-zig`, builds a lazy plan from `$` value wiring, executes needed `uses` entries, stores typed values, and exposes traces through `zinc://` URIs.

## Circuitry 0.6.1

```yaml
circuitry: "0.6.1"
name: compute math

takes:
  $principal:
    type: number
  $rate:
    type: number
  $years:
    type: number

uses:
  compound_interest:
    takes:
      principal: $principal
      rate: $rate
      years: $years
    does: |
      amount = principal * (1 + rate) ^ years
      interest = amount - principal
    gives:
      amount: $amount
      interest: $interest

gives:
  $amount:
    type: number
  $interest:
    type: number
```

Run it:

```bash
zn run examples/compute-math.circuitry.yaml principal=1000 rate=0.05 years=10
```

Zinc prints outputs and a run URI.

## Ownership

Circuitry owns `circuitry`, `name`, `about`, `takes`, `uses`, `does`, `gives`, and `$value` references.

Zinc owns `zinc`, `@package` references, `model`, model preset config, package resolution, adapter invocation, value storage, and traces.

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
```

## Runtime

Zinc derives dependency order from `$` references. A part is ready when all values in its local `takes` are available. When `runtime.parallel` is enabled, Zinc runs bounded ready waves concurrently, including inline parts, model-backed parts, and external/package shape parts. Workers return part results; Zinc commits values, reasoning, artifacts, and scoped child traces in plan order for deterministic runs. Values are stored with their type labels and can be read back:

```bash
zn inspect zinc://run/<run_id>
zn read 'zinc://run/<run_id>/value/$amount'
```

Inline parts can execute deterministic arithmetic assignment lines. Model-backed parts resolve through Zinc model presets and package-provided adapters. External and package-provided shapes run through the same value wiring as inline parts.

The first adapter package is public:

```text
zinc://package/openai-responses@0.1.4
https://github.com/darkhorseprojects/darkhorseprojects-packages/tree/main/openai-responses
```

It installs a self-contained global Zinc config for a local llama.cpp server on `127.0.0.1:30000`, with `context_window: 16384` and `reasoning.max_tokens: 512`.

## Configuration

Zinc reads `.zinc/config.yaml` and `~/.zinc/config.yaml`.

```yaml
runtime:
  parallel: true
  max_parallel: 0

models:
  default: fast

  fast:
    adapter: @responses.adapters.responses
    params:
      model: gpt-4.1-mini
      temperature: 0.2
```

## Packages

Package manifests are readable YAML and can expose `shapes`, `adapters`, `prompts`, `files`, `docs`, `assets`, and `scripts`. Circuitry files refer to package assets with `@alias.kind.name` and declare aliases under top-level `zinc.packages`.

Packages may declare `soft_dependencies`; Zinc reports them during inspect/install, never installs them automatically, and fails only when a missing optional package segment is used.

## Building

Zinc is written in Zig 0.16.0.

```bash
zig build
zig build test
```

## Learn more

- [Wiki](https://github.com/darkhorseprojects/zinc/wiki)
- [Circuitry](https://github.com/darkhorseprojects/circuitry/wiki)
