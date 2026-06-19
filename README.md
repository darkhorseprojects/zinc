[![Release](https://badgen.net/badge/Release/success/green?icon=github)](https://github.com/darkhorseprojects/zinc/actions/workflows/release.yml)
[![License](https://badgen.net/github/license/darkhorseprojects/zinc?label=License&color=black&icon=github)](LICENSE)

# Zinc

Zinc advances ready Circuitry value-boundary mappings by following `surface` refs into package surfaces.

Circuitry knows the format, `in` / `out`, and `$value` references. Zinc owns `packages`, `surface`, `preserve`, package installation, execution, memory, cache, and history. Packages expose surfaces and return YAML fields.

## Run

```bash
zn run examples/bash-status.circuitry.yaml command="pwd"
```

```yaml
circuitry: "0.8.2"
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

## Boundary

```text
Circuitry = format + value boundaries
surface   = Zinc navigation to package.surface
packages  = Zinc package hints
preserve  = Zinc storage policy
```

Everything else in a shape is user grouping or host/package metadata.

## Database

Zinc keeps package records and run history in `~/.zinc/zinc.db`.

The schema is intentionally small:

```text
meta
packages
events
packets
```

`packages` records installed package roots and URIs. `events` records each package surface invocation. `packets` stores the YAML requests, responses, and selected outputs referenced by those events.

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
