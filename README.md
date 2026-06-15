[![Release](https://badgen.net/github/checks/darkhorseprojects/zinc/main/release.yml?label=Release&icon=github)](https://github.com/darkhorseprojects/zinc/actions/workflows/release.yml)
[![License](https://badgen.net/github/license/darkhorseprojects/zinc?label=License&color=black&icon=github)](LICENSE)

# Zinc

Zinc stores package facts, exact work bytes, and current pointers.

It is a small layer over Limbo. Circuitry confirms shape files, packages provide behavior, and Zinc records the bytes and package roots needed to inspect or replay work.

## At a glance

| Area | Zinc responsibility |
| --- | --- |
| Packages | Record package name, version, root, and source facts. |
| Shapes | Store raw Circuitry bytes and confirm shape facts with Circuitry. |
| Fragments | Store target, request, result, and time as exact bytes. |
| Heads | Point a target/request identity to its current fragment. |
| Config | Store opaque configuration values. |
| Package software | Run package programs through a request-file boundary. |

## Run

```bash
zn run examples/local-llama-answer.circuitry.yaml question="What is Zinc?"
```

A run reads a shape, confirms it, builds a package request, runs package software, stores the result bytes, and moves the matching head to the resulting fragment.

```text
shape bytes -> confirmed shape -> package request -> package software -> result bytes -> fragment -> head
```

## Store

```text
packages(package, version, root, source_git, source_ref, source_path)
fragments(fragment, target, request, result, time)
heads(head, fragment)
config(key, value)
```

A head identifies a target and request:

```text
head = hash(target + request)
```

A fragment identifies a target, request, and result:

```text
fragment = hash(target + request + result)
```

## CLI

```bash
# Run and inspect
zn run examples/compute-math.circuitry.yaml a=2 b=3
zn inspect zinc://fragments
zn inspect zinc://heads
zn inspect zinc://config

# Read package facts and files
zn read zinc://packages
zn read zinc://packages/openai-responses/manifest/software/responses
zn read zinc://packages/openai-responses/files/software/responses.py

# Manage packages
zn pkg install ./openai-responses --global
zn pkg list
zn pkg check openai-responses
zn pkg update openai-responses
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
  run: openai-responses.software.responses
```

The value is a package reference. The selected package decides what it means.

## Read more

- [Architecture](https://github.com/darkhorseprojects/zinc/wiki/Architecture)
- [Fragments and Heads](https://github.com/darkhorseprojects/zinc/wiki/Fragments-and-Heads)
- [Packages](https://github.com/darkhorseprojects/zinc/wiki/Packages)
- [Package Software](https://github.com/darkhorseprojects/zinc/wiki/Package-Software)
- [Executor](https://github.com/darkhorseprojects/zinc/wiki/Executor)

## Building

```bash
zig build
zig build test
```
