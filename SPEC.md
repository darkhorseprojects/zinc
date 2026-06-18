# Zinc Specification

Zinc resolves package software, sends it the selected Circuitry action request, records exact request/output bytes, and routes named outputs back into the run.

## Package manifest

A package is a directory with `zinc.pkg.yaml`.

Required fields:

```yaml
name: package-name
version: "0.1.0"
software:
  surface:
    python: software/run.py
    gives: gives
```

Common optional fields:

```yaml
about: Human-readable package description.
source:
  uri: https://example/repo.git
  ref: package-v0.1.0
  path: package-name
links:
  other-package: "0.1.0"
settings:
  defaults: settings/defaults.yaml
docs:
  readme: docs/README.md
scripts:
  test: scripts/test
examples:
  request: examples/request.yaml
```

Optional material sections are navigable package facts. Zinc may read them; packages own their meaning.

## Software refs

A software ref has this form:

```text
package.software
```

Example:

```text
openai-responses.responses
unix-bash.bash
```

The package part resolves an installed package. The software part selects an entry under `software` in that package manifest.

## Software entries

A software entry defines how Zinc runs one package-owned surface.

```yaml
software:
  responses:
    about: Produce model text, reasoning text, and requested named outputs.
    python: software/responses.py
    args: []
    cwd: .
    env:
      NAME: value
    gives: gives
```

Exactly one runner is required today:

```yaml
python: software/run.py
```

or

```yaml
command: executable
```

`about`, `args`, `cwd`, and `env` are optional.

## Package request

Zinc always sends the selected package request to software stdin.

The request is built from the Circuitry action and its host fields:

```yaml
software: openai-responses.responses
model: local-llama
does: |
  Answer briefly.
takes:
  question: "What is Zinc?"
gives:
  answer: "$answer"
```

Zinc does not declare this request shape in the package manifest. Circuitry owns the action shape. Zinc owns request construction. Package software owns interpretation.

## Software output and `gives`

Package software writes YAML to stdout. The software entry's `gives` field tells Zinc how to select requested local outputs from that stdout.

Preferred dynamic form:

```yaml
software:
  bash:
    python: software/run.py
    gives: gives
```

This means requested local output `name` is selected from:

```text
stdout.gives.name
```

Preferred stdout:

```yaml
gives:
  output: |
    stdout text
  error: |
    stderr text
  exit: |
    0
```

Fixed selector form:

```yaml
software:
  thing:
    command: existing-program
    gives:
      answer: result.answer
      score: metrics.score
```

This means requested local output `answer` is selected from `stdout.result.answer`.

Zinc maps only outputs requested by the Circuitry action. Missing requested outputs fail the action.

## Lineage

For every executed package action, Zinc records:

- the exact package request bytes
- the exact package stdout bytes
- the selected action identity

Zinc does not reinterpret package-specific result meaning in lineage. Packages own output schemas; Circuitry owns routing names; Limbo stores immutable bytes/current state.

## Boundary

Zinc does not own package tests, scripts, model prompts, command policy, provider behavior, or documentation semantics.

Zinc owns:

- installed package records
- software ref resolution
- process invocation
- package request construction
- output selection from `software.<name>.gives`
- lineage recording

Packages own:

- software behavior
- settings
- docs
- scripts
- examples
- prompt construction
- output meaning
