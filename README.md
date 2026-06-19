[![Release](https://badgen.net/badge/Release/success/green?icon=github)](https://github.com/darkhorseprojects/zinc/actions/workflows/release.yml)
[![License](https://badgen.net/github/license/darkhorseprojects/zinc?label=License&color=black&icon=github)](LICENSE)

# Zinc

Zinc advances ready Circuitry surface mappings through package surfaces.

Circuitry flattens grouped value boundaries. Packages expose surfaces and return YAML fields. Zinc keeps current values in memory, uses OS temp as cache, and records events/packets in Limbo.

## Run

```bash
zn run examples/bash-status.circuitry.yaml command="pwd"
```

```yaml
circuitry: "0.8.1"
name: bash status snapshot

in:
  - $command

shell:
  status:
    surface: unix-bash.bash
    in:
      command: $command
    out:
      output: $output
      exit: $exit

out:
  - $output
  - $exit
```

## Store

```text
memory = current values
cache  = OS temp
DB     = what happened
```

The DB uses small tables for `meta`, `packages`, `events`, and `packets`. Current values stay in the runner; cached files stay in the OS temp area; recorded packets and events stay in the DB.

## CLI

```bash
zn run examples/local-llama-answer.circuitry.yaml question="What is Zinc?"
zn read zinc://packages/openai-responses/manifest/surfaces/responses
zn read zinc://packages/openai-responses/files/surfaces/responses.py
zn pkg install ./openai-responses --global
zn pkg list
zn pkg requires
zn pkg update openai-responses --dry-run
zn config
zn update --check
```

## Packages

A package is a directory with `zinc.pkg.yaml`.

```yaml
name: openai-responses
version: "0.4.1"
about: OpenAI Responses model package.
uri: git+https://github.com/darkhorseprojects/darkhorseprojects-packages.git@openai-responses-v0.4.1//openai-responses

requires:
  unix-bash: "0.2.1"

surfaces:
  responses:
    about: Produce model responses.
    python: surfaces/responses.py
```

Package surfaces receive YAML on stdin and return YAML top-level fields on stdout.

## Configuration

Zinc reads:

```text
.zinc/config.yaml
~/.zinc/config.yaml
```

Example:

```yaml
defaults:
  surface: openai-responses.responses
```

## Building

```bash
zig build
zig build test
```
