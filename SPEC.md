# Zinc Specification

Zinc advances ready Circuitry surface mappings, sends YAML requests to package surfaces, routes returned YAML fields into memory, and records events/packets in Limbo.

## Package manifest

```yaml
name: package-name
version: "0.1.0"
uri: git+https://example/repo.git@package-v0.1.0//package-name

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

## Circuitry mappings

Zinc treats any Circuitry mapping with `surface` as executable.

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

`preserve` is Zinc policy. If absent, final top-level outputs are preserved and intermediate values are transient.

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

## Store

```text
memory = current values
cache  = OS temp
DB     = what happened
```

DB tables:

```text
meta
packages
events
packets
```

Current values live in memory. Cache files live in the OS temp area. Recorded requests, responses, and outputs live in the DB.

## Boundary

Zinc owns package installation records, URI resolution, process invocation, request construction, direct field selection, memory/cache/db policy, and event recording.

Packages own behavior, settings, docs, scripts, examples, prompt construction, and response meaning.
