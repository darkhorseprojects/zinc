# Zinc Specification

Zinc resolves package surface, sends it the selected Circuitry action request, records exact request/response bytes, and routes named outputs back into the run.

## Package manifest

A package is a directory with `zinc.pkg.yaml`.

Required fields:

```yaml
name: package-name
version: "0.1.0"
surfaces:
  surface:
    python: surfaces/run.py
    response: response
```

Common optional fields:

```yaml
about: Human-readable package description.
source:
  uri: https://example/repo.git
  ref: package-v0.1.0
  path: package-name
requires:
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

## Surface refs

A surface ref has this form:

```text
package.surface
```

Example:

```text
openai-responses.responses
unix-bash.bash
```

The package part resolves an installed package. The surface part selects an entry under `surfaces` in that package manifest.

## Surface entries

A surface entry defines how Zinc runs one package-owned surface.

```yaml
surfaces:
  responses:
    about: Produce model text, reasoning text, and requested named outputs.
    python: surfaces/responses.py
    args: []
    cwd: .
    env:
      NAME: value
    response: response
```

Exactly one runner is required today:

```yaml
python: surfaces/run.py
```

or

```yaml
command: executable
```

`about`, `args`, `cwd`, and `env` are optional.

## Package request

Zinc always sends the selected package request to surface stdin.

The request is built from the Circuitry action and its host fields:

```yaml
surface: openai-responses.responses
model: local-llama
text: |
  Answer briefly.
in:
  question: "What is Zinc?"
out:
  answer: "$answer"
```

Zinc does not declare this request shape in the package manifest. Circuitry owns the action shape. Zinc owns request construction. Package surface owns interpretation.

## Surface output and `response`

Package surface writes YAML to stdout. The surface entry's `response` field tells Zinc how to select requested local outputs from that stdout.

Preferred dynamic form:

```yaml
surfaces:
  bash:
    python: surfaces/run.py
    response: response
```

This means requested local output `name` is selected from:

```text
stdout.response.name
```

Preferred stdout:

```yaml
response:
  output: |
    stdout text
  error: |
    stderr text
  exit: |
    0
```

Fixed selector form:

```yaml
surfaces:
  thing:
    command: existing-program
    out:
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
- surface ref resolution
- process invocation
- package request construction
- response selection from `surfaces.<name>.response`
- lineage recording

Packages own:

- surface behavior
- settings
- docs
- scripts
- examples
- prompt construction
- output meaning
