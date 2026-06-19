[![Release](https://badgen.net/badge/Release/success/green?icon=github)](https://github.com/darkhorseprojects/zinc/actions/workflows/release.yml)
[![License](https://badgen.net/github/license/darkhorseprojects/zinc?label=License&color=black&icon=github)](LICENSE)

# Zinc

Zinc is the environment-native runtime for Circuitry.

Circuitry makes agentic work open and reusable by fixing the value shape in YAML: named values, inputs, outputs, and `$value` references. Zinc runs that work in the user's environment by resolving explicit package surfaces, invoking local software, routing YAML fields, and recording run history.

Packages are Zinc's extension model. They own software, prompts, policy, docs, settings, and orchestration. Zinc only requires that a package surface receives YAML and returns YAML.

```bash
zn run task.circuitry.yaml question="what changed?"
```

## Shape

```yaml
circuitry: "0.8.2"
name: ask and check

in:
  - $question

answer:
  surface: openai-responses.responses
  model: local-llama
  in:
    question: $question
  out:
    answer: $answer

check:
  surface: unix-bash.bash
  in:
    command: pwd
  out:
    output: $cwd
    exit: $exit

out:
  - $answer
  - $cwd
  - $exit
```

```bash
zn run ask.circuitry.yaml question="summarize this project"
```

Zinc runs entries when their inputs are available. Independent entries may run in the same ready wave according to `runtime.parallel`.

## Package surfaces

A package is a directory with `zinc.pkg.yaml`.

```yaml
name: unix-bash
uri: git+https://github.com/darkhorseprojects/darkhorseprojects-packages.git@unix-bash-v0.2.4//unix-bash

surfaces:
  bash:
    about: Run one Bash command through package policy.
    python: surfaces/run.py

settings:
  defaults: settings/defaults.yaml
  policy: settings/policy.yaml
```

Zinc types only:

```text
name
uri
surfaces
```

Everything else is package-owned data and is readable through `zinc://`.

```bash
zn read zinc://packages/unix-bash/manifest/settings
zn read zinc://packages/unix-bash/files/docs/README.md
```

## YAML protocol

Zinc sends YAML to package stdin:

```yaml
surface: unix-bash.bash
in:
  command: pwd
out:
  output: $output
  exit: $exit
```

The package writes direct YAML fields to stdout:

```yaml
output: |
  /home/colin/dev/zinc
exit: 0
```

Zinc selects only the fields requested by the shape.

## Package-owned orchestration

Packages may call Zinc.

```bash
cat generated.circuitry.yaml | zn run --report -
```

That is the extension point: generate a shape, run it, inspect the report, continue. Zinc remains the runner. The package owns the loop.

## Run sources

```bash
zn run file.circuitry.yaml
zn run file.circuitry.md
zn run zinc://packages/zinc-chat/files/shapes/chat.circuitry.yaml
cat graph.circuitry.yaml | zn run -
cat graph.circuitry.yaml | zn run --report -
```

Markdown files use leading YAML front matter as the runnable shape.

## Run history

Zinc stores package records and run history in:

```text
~/.zinc/zinc.db
```

Core history tables:

```text
runs
steps
packets
```

Read them with:

```bash
zn read zinc://runs
zn read zinc://runs/<id>
zn read zinc://runs/<id>/current
zn read zinc://runs/<id>/steps
zn read zinc://steps/<id>
zn read zinc://packets/<id>
```

Use run navigation when continuing or forking work:

```bash
zn run - in zinc://runs/<id>
zn run - from zinc://steps/<id>
zn set zinc://runs/<id>/current zinc://steps/<id>
```

## Packages

```bash
zn pkg install ./unix-bash --global
zn pkg list
zn pkg update unix-bash --dry-run
zn pkg update all --global --yes
zn pkg remove unix-bash
```

`zn pkg update` uses installed package URIs. For git package URIs, Zinc checks matching package tags and updates only packages explicitly requested.

`neighbors`, if present, is raw package-owned manifest data. Zinc exposes it through `zn read` but does not resolve, install, update, or order from it.

## Configuration

Zinc reads the first config file it finds:

```text
.zinc/config.yaml
~/.zinc/config.yaml
```

```yaml
runtime:
  parallel: 4

packages:
  openai-responses:
    packet_limit: 1048576
  unix-bash:
    packet_limit: 262144
```

Missing config uses internal defaults. Malformed config fails loudly.

## Updating Zinc

```bash
zn update --check
zn update
```

Standalone installs can self-update. Package-manager-owned installs refuse self-replacement and print the manager command to use instead.

## Boundary

```text
Circuitry = open YAML value boundaries
Zinc     = environment-native execution + history
Packages = extension surfaces + package-owned meaning
```

Zinc owns:

```text
shape loading
package records
surface resolution
process invocation
YAML request construction
YAML field routing
runtime parallelism
packet limits
run history
package install/update
standalone binary update
```

Packages own:

```text
behavior
policy
settings
prompts
docs
software
orchestration
relationship semantics
```

Circuitry owns:

```text
YAML value boundaries
root in / root out
entry in / entry out
$value references
```

## Learn more

- [Zinc wiki](https://github.com/darkhorseprojects/zinc/wiki)
- [Zinc specification](SPEC.md)
- [Circuitry](https://github.com/darkhorseprojects/circuitry)
- [Dark Horse Projects packages](https://github.com/darkhorseprojects/darkhorseprojects-packages)

## Build

```bash
zig build
zig build test
```
