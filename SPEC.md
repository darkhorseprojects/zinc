# Zinc Specification

Zinc advances ready Circuitry value-boundary mappings by following `surface` refs into package surfaces. It sends YAML requests, routes returned YAML fields into the active run, and records package/run history in Limbo.

## Package manifest

```yaml
name: package-name
version: "0.1.0"
uri: git+https://example/repo.git@package-v0.1.0//package-name

neighbors:
  other-package: "0.1.0"

surfaces:
  surface:
    python: surfaces/run.py
```

Optional material sections are navigable package facts. Zinc may read them; packages own their meaning.

## Surface refs

```text
package.surface
```

The package part resolves an installed package. The surface part selects an entry under `surfaces` in that package manifest.

## Surface entries

```yaml
surfaces:
  responses:
    about: Produce model responses.
    python: surfaces/responses.py
    args: []
    cwd: .
    env:
      NAME: value
```

Exactly one runner is required today: `python` or `command`.

## Circuitry and Zinc fields

Circuitry owns the shape format, root `in`, root `out`, entry `in`, entry `out`, and `$value` references.

Zinc owns host fields such as `surface` and `preserve`.

A Zinc-executable entry is a Circuitry-discovered value-boundary mapping whose host fields include `surface`.

```yaml
answer:
  surface: openai-responses.responses
  preserve: true
  model: local-llama
  in:
    question: $question
    prompt: Answer briefly.
  out:
    answer: $answer
```

`surface` is Zinc navigation to `package.surface`. `preserve` is Zinc storage policy. If `preserve` is absent, final top-level outputs are preserved and intermediate values are transient.

## Package request

Zinc sends YAML to stdin:

```yaml
surface: openai-responses.responses
model: local-llama
in:
  question: What is Zinc?
  prompt: Answer briefly.
out:
  answer: $answer
```

Zinc does not type or interpret package fields. Packages own request meaning.

## Package response

Package stdout is YAML with requested local names as top-level fields:

```yaml
answer: |
  Zinc advances package surfaces through Circuitry value flow.
reasoning: |
  ...
```

Zinc maps only outputs requested by the Circuitry entry. Missing requested outputs fail the entry.

## Database

Zinc stores package records and run history in Limbo.

```text
meta
packages
events
packets
```

`packages` records installed package roots and URIs. `events` records package surface invocations. `packets` stores the YAML requests, responses, and selected outputs referenced by those events.

## Boundary

Circuitry owns shaped value flow.

Zinc owns package installation records, URI resolution, `surface` navigation, process invocation, request construction, direct field selection, package packet limits, runtime parallelism, and event recording.

Packages own behavior, settings, docs, scripts, examples, prompt construction, and response meaning.
