# Zinc

Zinc remembers fragments and moves heads.

Circuitry confirms shaped YAML and variables. Packages own software, settings, docs, shells, providers, and request/result interpretation. Zinc keeps package identity, manifest navigation, opaque config, exact byte fragments, and head pointers over Limbo.

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

Execution is visible through Zinc's fragment store:

```bash
zn inspect zinc://packages
zn inspect zinc://fragments
zn inspect zinc://heads
zn inspect zinc://config
zn read zinc://fragments/<fragment>
zn read zinc://heads/<head>
```

The core tables are intentionally small:

```text
packages(package, version, root, source_git, source_ref, source_path)
fragments(fragment, target, request, result, time)
heads(head, fragment)
config(key, value)
```

A fragment is exact byte work. Its identity is derived from the target, exact request bytes, and exact result bytes. A head is the current pointer from target/request identity to a fragment.

```text
head     = hash(target + request)
fragment = hash(target + request + result)
```

`does` is instruction bytes passed to package software. It is not shell text, arithmetic, or Zinc code.

## Configuration

Zinc reads `.zinc/config.yaml` and `~/.zinc/config.yaml`.

```yaml
defaults:
  run: openai-responses.software.responses
```

The value is an opaque package ref. Zinc does not open it as a native model profile. Packages interpret their own settings.

## Packages

A package is an arbitrary self-contained directory with `zinc.pkg.yaml`. Zinc registers package identity and root; it does not catalog package files into its database.

```yaml
name: openai-responses
version: "0.3.0"
about: OpenAI Responses-shaped model package.

source:
  git: https://github.com/darkhorseprojects/darkhorseprojects-packages.git
  ref: openai-responses-v0.3.0
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

References are manifest paths:

```text
openai-responses.software.responses
openai-responses.settings.models
openai-responses.shapes.short_answer
```

Package systems integrate at their package boundary. Zinc does not absorb npm, Python, shell, PowerShell, provider, or OS-specific internals.

## Building

Zinc is written in Zig 0.16.0.

```bash
zig build
zig build test
```
