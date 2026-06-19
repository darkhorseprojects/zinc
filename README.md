[![Release](https://badgen.net/badge/Release/success/green?icon=github)](https://github.com/darkhorseprojects/zinc/actions/workflows/release.yml)
[![License](https://badgen.net/github/license/darkhorseprojects/zinc?label=License&color=black&icon=github)](LICENSE)

# Zinc

Zinc is a programmable runtime for package-owned software.

It runs Circuitry shapes: YAML graphs whose executable entries name package surfaces. A surface can be anything a package owns: a model call, a shell command, a scraper, a compiler step, a chat loop, a data transform, or a local tool.

Zinc does not invent a tool API. It uses YAML.

- Circuitry describes value flow.
- Zinc resolves and runs explicit `surface` calls.
- Packages own behavior, policy, prompts, settings, docs, and software.
- Every package call receives YAML and returns YAML.
- Zinc records package installs and run history.

```bash
zn run task.circuitry.yaml question="what changed?"
```

## Why Zinc exists

Most automation systems either hard-code tools into the host or hide execution behind a framework-specific object model.

Zinc keeps the boundary small:

```yaml
surface: openai-responses.responses
in:
  question: What is Zinc?
out:
  answer: $answer
```

The host only knows how to run the named surface and route returned fields. The package decides what `question` means, what model to use, what policy applies, and what files or prompts are involved.

That makes Zinc useful for:

- model pipelines
- shell-backed workflows
- package-owned chat loops
- local automation
- reproducible experiments
- composable project tools
- inspectable AI/runtime history

## A shape

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
    command: "pwd"
  out:
    output: $cwd
    exit: $exit

out:
  - $answer
  - $cwd
  - $exit
```

Run it:

```bash
zn run ask.circuitry.yaml question="summarize this project"
```

Zinc runs entries when their inputs are available. Independent entries can run in parallel according to `runtime.parallel`.

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

docs:
  readme: docs/README.md
```

Zinc types only the runtime fields it needs:

```text
name
uri
surfaces
```

Everything else is package-owned data and can be read through `zinc://`.

```bash
zn read zinc://packages/unix-bash/manifest/settings
zn read zinc://packages/unix-bash/files/docs/README.md
```

## YAML is the protocol

Zinc sends package surfaces YAML on stdin:

```yaml
surface: unix-bash.bash
in:
  command: pwd
out:
  output: $output
  exit: $exit
```

The package writes YAML to stdout:

```yaml
output: |
  /home/colin/dev/zinc
exit: 0
```

Zinc selects only the fields requested by the shape.

## Package-owned orchestration

Because `zn run` accepts stdin and can emit structured reports, packages can generate and run shapes themselves.

```bash
cat generated.circuitry.yaml | zn run --report -
```

This is enough to build higher-level packages such as `zinc-chat` without adding chat or tool logic to Zinc core.

A chat package can:

1. read installed packages with `zn read zinc://packages`
2. ask a model package for a YAML call plan
3. validate that plan
4. generate a temporary Circuitry graph
5. run it with `zn run --report -`
6. feed results back to the model
7. return a final reply

Zinc remains the runner. The package owns the loop.

## Run sources

```bash
zn run file.circuitry.yaml
zn run file.circuitry.md
zn run zinc://packages/zinc-chat/files/shapes/chat.circuitry.yaml
cat graph.circuitry.yaml | zn run -
cat graph.circuitry.yaml | zn run --report -
```

Markdown files use YAML front matter as the runnable shape and leave the body for human notes.

## Packages

```bash
zn pkg install ./unix-bash --global
zn pkg list
zn pkg update unix-bash --dry-run
zn pkg update all --global --yes
zn pkg remove unix-bash
```

`zn pkg update` uses the installed package URI. For git package URIs, Zinc checks matching package tags and updates only packages you explicitly ask it to update.

`neighbors`, if present in a manifest, is raw package-owned metadata. Zinc exposes it through `zn read` but does not resolve, install, update, or order from it.

## Configuration

Zinc reads:

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

## History

Zinc stores package records and surface invocations in:

```text
~/.zinc/zinc.db
```

Tables:

```text
meta
packages
events
packets
```

The database is runtime history, not application state. Packages may read it, but Zinc does not turn history into chat memory, workflow state, or policy.

## Updating Zinc

```bash
zn update --check
zn update
```

Standalone installs can self-update.

If Zinc is owned by a package manager, `zn update` refuses to replace the binary and prints the manager command instead, such as:

```text
Use: paru -Syu zinc
Use: yay -Syu zinc
Use: sudo pacman -Syu zinc
Use: brew upgrade zinc
Use: npm update -g @darkhorseprojects/zinc
```

## Boundary

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
chat loops
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

- [Zinc wiki](https://github.com/darkhorseprojects/zinc/wiki) — architecture, package surfaces, executor behavior, configuration, URI references, and package updates.
- [Zinc specification](SPEC.md) — concise runtime contract and boundaries.
- [Circuitry](https://github.com/darkhorseprojects/circuitry) — YAML value-boundary format used by Zinc shapes.
- [Dark Horse Projects packages](https://github.com/darkhorseprojects/darkhorseprojects-packages) — package manifests, surfaces, docs, prompts, settings, and package-owned software.

## Build

```bash
zig build
zig build test
```
