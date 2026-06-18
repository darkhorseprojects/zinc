[![Release](https://badgen.net/badge/Release/success/green?icon=github)](https://github.com/darkhorseprojects/zinc/actions/workflows/release.yml)
[![License](https://badgen.net/github/license/darkhorseprojects/zinc?label=License&color=black&icon=github)](LICENSE)

# Zinc

Zinc runs Circuitry shapes through package software and records lineage.

Circuitry describes the shape. Packages provide behavior. Zinc connects them and stores the exact request/result bytes.

## At a glance

| Area | Zinc responsibility |
| --- | --- |
| Packages | Record package name, version, root, source facts, and soft links. |
| Shapes | Parse Circuitry files and build package-facing context. |
| Lineage | Store request/result bytes as blobs and immutable nodes. |
| Config | Store opaque configuration values. |
| Package software | Run the selected package command with selected context on stdin. |

## Run

```bash
zn run examples/local-llama-answer.circuitry.yaml question="What is Zinc?"
```

A run reads a shape, confirms value flow with Circuitry, builds context for each package action, runs package software, and stores the package-facing request/result bytes.

```text
shape -> Circuitry facts -> package context -> package software -> request/result bytes
```

## Store

Zinc stores lineage in Limbo. Small request/result blobs live in the database. Large blobs live under Zinc's blob directory and are referenced by hash.

## CLI

```bash
# Run and inspect
zn run examples/compute-math.circuitry.yaml a=2 b=3
zn inspect zinc://config

# Read package facts and files
zn read zinc://packages
zn read zinc://packages/openai-responses/manifest/software/responses
zn read zinc://packages/openai-responses/files/software/responses.py

# Manage packages
zn pkg install ./openai-responses --global
zn pkg list
zn pkg links
zn pkg update openai-responses --dry-run
zn pkg remove openai-responses

# Maintain Zinc
zn config
zn update --check
zn update
```

## Packages

A package is a directory with `zinc.pkg.yaml`.

```yaml
name: openai-responses
version: "0.3.11"
about: OpenAI Responses model package.

source:
  uri: https://github.com/darkhorseprojects/darkhorseprojects-packages.git
  ref: openai-responses-v0.3.11
  path: openai-responses

links:
  unix-bash: "0.1.3"

interface:
  request: context
  output:
    answer: gives.answer

software:
  responses:
    python: software/responses.py

shapes:
  short_answer: shapes/short-answer.circuitry.yaml

settings:
  models: settings/models.yaml

docs:
  readme: docs/README.md
```

Zinc records package identity and reads manifest paths. Package software, settings, models, scripts, and documentation belong to the package.

## Configuration

Zinc reads:

```text
.zinc/config.yaml
~/.zinc/config.yaml
```

Example:

```yaml
defaults:
  software: openai-responses.responses
```

The value is a package ref. The selected package decides what it means.

## Read more

- [Architecture](https://github.com/darkhorseprojects/zinc/wiki/Architecture)
- [Packages](https://github.com/darkhorseprojects/zinc/wiki/Packages)
- [Package Software](https://github.com/darkhorseprojects/zinc/wiki/Package-Software)
- [Executor](https://github.com/darkhorseprojects/zinc/wiki/Executor)

## Building

```bash
zig build
zig build test
```
