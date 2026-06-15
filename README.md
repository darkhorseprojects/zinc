[![Release](https://github.com/darkhorseprojects/zinc/actions/workflows/release.yml/badge.svg?branch=main)](https://github.com/darkhorseprojects/zinc/actions/workflows/release.yml)
[![License](https://img.shields.io/badge/license-MIT-475569.svg?style=for-the-badge)](LICENSE)

# Zinc

Zinc is a small memory and navigation layer for shaped work.

It keeps three things clear: which packages are installed, which exact request and result bytes were used, and which fragment a target is currently pointing to. Zinc does not interpret package behavior. Packages decide what their software, settings, models, scripts, and documents mean.

## Why use Zinc

Zinc is useful when you want a reliable record of work without turning every package into shared execution behavior.

- Keep package identity and roots in one place.
- Store exact request and result bytes as fragments.
- Move a target/request head to the fragment that produced the result.
- Read package manifests and files without importing package internals.
- Run package software through a simple file-based request boundary.

## What is stored

Zinc stores a small set of records:

| Table | Purpose |
| --- | --- |
| `packages` | Installed package identity, version, root, and source facts. |
| `fragments` | Exact request and result bytes for one piece of work. |
| `heads` | Current fragment pointer for a target and request. |
| `config` | Opaque Zinc configuration values. |

A head identifies the target and request:

```text
head = hash(target + request)
```

A fragment identifies the target, request, and result:

```text
fragment = hash(target + request + result)
```

This keeps the store simple: Zinc remembers the bytes and the pointer. It does not define the meaning of those bytes.

## How a run works

A run starts with a Circuitry shape.

```bash
zn run examples/local-llama-answer.circuitry.yaml question="What is Zinc?"
```

Zinc reads the shape bytes, confirms the shape, builds the package request, runs the package software, stores the result bytes, and moves the matching head to the resulting fragment.

```text
shape bytes -> confirmed shape -> package request -> package software -> result bytes -> fragment -> head
```

The package software receives a request file path and returns bytes. Zinc does not decide how the package reads settings, calls a model, uses a shell, or formats its answer.

## Common commands

```bash
# Run a shape
zn run examples/compute-math.circuitry.yaml a=2 b=3

# Read package facts or files
zn read zinc://packages
zn read zinc://packages/openai-responses/manifest/software/responses
zn read zinc://packages/openai-responses/files/software/responses.py

# Inspect the store
zn inspect zinc://fragments
zn inspect zinc://heads
zn inspect zinc://config

# Manage packages
zn pkg install ./openai-responses --global
zn pkg list
zn pkg check openai-responses
zn pkg update openai-responses
zn pkg remove openai-responses
```

## Packages

A package is a directory with a `zinc.pkg.yaml` manifest.

Zinc records the package name, version, root, and source facts. The rest of the manifest is package-owned.

```yaml
name: openai-responses
version: "0.3.3"
about: OpenAI Responses-shaped model package.

source:
  git: https://github.com/darkhorseprojects/darkhorseprojects-packages.git
  ref: openai-responses-v0.3.3
  path: openai-responses

software:
  responses: software/responses.py

shapes:
  short_answer: shapes/short-answer.circuitry.yaml

settings:
  models: settings/models.yaml

docs:
  readme: docs/README.md
```

This keeps Zinc small. Package behavior belongs in the package.

## Configuration

Zinc reads configuration from:

```text
.zinc/config.yaml
~/.zinc/config.yaml
```

A common value is the default package software path:

```yaml
defaults:
  run: openai-responses.software.responses
```

The value is a package reference. The selected package decides what that reference means.

## Related projects

- [Circuitry](https://github.com/darkhorseprojects/circuitry) confirms shaped YAML and variables.
- [circuitry-zig](https://github.com/darkhorseprojects/circuitry-zig) reads Circuitry from Zig.
- [limbo-zig](https://github.com/darkhorseprojects/limbo-zig) stores rows and bytes.
- [darkhorseprojects-packages](https://github.com/darkhorseprojects/darkhorseprojects-packages) contains independent software and settings packages.

## Read more

- [Architecture](https://github.com/darkhorseprojects/zinc/wiki/Architecture)
- [Fragments and Heads](https://github.com/darkhorseprojects/zinc/wiki/Fragments-and-Heads)
- [Packages](https://github.com/darkhorseprojects/zinc/wiki/Packages)
- [Executor](https://github.com/darkhorseprojects/zinc/wiki/Executor)
- [URI Reference](https://github.com/darkhorseprojects/zinc/wiki/URI-Reference)

## Building

Zinc is written in Zig 0.16.0.

```bash
zig build
zig build test
```
