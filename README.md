[![Release](https://badgen.net/badge/Release/success/green?icon=github)](https://github.com/darkhorseprojects/zinc/actions/workflows/release.yml)
[![License](https://badgen.net/github/license/darkhorseprojects/zinc?label=License&color=black&icon=github)](LICENSE)

# Zinc

Zinc is the host runtime for Circuitry shapes.

It does three things:

1. read a Circuitry shape
2. run package surfaces whose entries explicitly name `surface`
3. record package installs and surface invocations in `~/.zinc/zinc.db`

Circuitry stays YAML-shaped. Packages own behavior. Zinc owns execution, package navigation, package limits, runtime parallelism, and history.

## Run a shape

```bash
zn run examples/bash-status.circuitry.yaml command="pwd"
```

```yaml
circuitry: "0.8.2"
name: bash status

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

Zinc only executes entries with `surface`. Everything else is user grouping, package metadata, or host policy.

## Markdown shapes

`zn run` accepts both Circuitry YAML files and Markdown files with YAML front matter.

```md
---
circuitry: "0.8.2"
name: bash status

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
---

# Bash status

Human notes can live here. Zinc ignores this body and runs only the front matter.
```

## Packages

A package is a directory with `zinc.pkg.yaml`.

```yaml
name: openai-responses
about: OpenAI Responses model package.
uri: git+https://github.com/darkhorseprojects/darkhorseprojects-packages.git@openai-responses-v0.4.4//openai-responses

neighbors:
  unix-bash: "0.2.4"

surfaces:
  responses:
    about: Produce model text and requested named outputs.
    python: surfaces/responses.py
```

The package version comes from the URI tag. Do not put `version` in the manifest.

`neighbors` is inspection metadata only. Zinc never installs or updates neighbors automatically.

## Configuration

Zinc reads:

```text
.zinc/config.yaml
~/.zinc/config.yaml
```

Example:

```yaml
runtime:
  parallel: 4

packages:
  openai-responses:
    packet_limit: 1048576
  unix-bash:
    packet_limit: 262144
  powershell:
    packet_limit: 262144
```

`runtime.parallel` limits concurrent surface invocations in one ready wave. `packages.<name>.packet_limit` controls stored packet tails for events from that package.

## Package commands

```bash
zn pkg install ./openai-responses --global
zn pkg list
zn pkg neighbors
zn pkg neighbors --missing
zn pkg update openai-responses --dry-run
zn pkg update all --global --yes
```

`zn pkg update` uses the installed package URI. For git package URIs, Zinc checks package tags, compares the installed version to the newest matching tag, and updates only the package you asked for.

## Read package material

```bash
zn read zinc://packages/openai-responses/manifest/neighbors
zn read zinc://packages/openai-responses/files/surfaces/responses.py
```

## History

Zinc stores package records and run history in `~/.zinc/zinc.db`.

```text
meta
packages
events
packets
```

- `packages` records installed package roots and source URIs.
- `events` records package surface invocations.
- `packets` stores YAML requests, responses, and selected outputs referenced by those events.

## CLI

```bash
zn run <shape.yaml-or-md> [name=value ...]
zn read <uri-or-file>
zn inspect <uri-or-file>
zn pkg install <path-or-uri> [--global|--workspace]
zn pkg remove <package>
zn pkg list
zn pkg neighbors [--missing]
zn pkg update <package|all> [--global|--workspace] [--dry-run] [--yes]
zn config
zn update --check
zn update
```

## Build

```bash
zig build
zig build test
```
