# Zinc Specification

Zinc is the environment-native runtime for Circuitry shapes.

Circuitry defines reusable YAML value boundaries. Zinc executes entries that explicitly name package surfaces. Packages own the surface behavior.

## Package manifest

```yaml
name: package-name
uri: git+https://example/repo.git@package-v0.1.0//package-name

neighbors:
  other-package: git+https://example/repo.git@other-package-v0.1.0//other-package

surfaces:
  surface:
    python: surfaces/run.py
```

Zinc types only:

```text
name
uri
surfaces
```

The package version comes from the URI tag. `version` is not a manifest field.

`neighbors` is raw package-owned data. Zinc exposes it through `zn read`; it does not resolve or install from it.

## Surface refs

```text
package.surface
```

The package part resolves an installed package. The surface part selects a manifest surface.

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

A surface currently uses either `python` or `command`.

## Shape fields

Circuitry owns:

```text
circuitry
name
about
root in / root out
entry in / entry out
$value references
```

Zinc owns host fields such as:

```text
surface
preserve
```

All other host fields are passed to the package request unless Zinc explicitly defines them.

```yaml
answer:
  surface: openai-responses.responses
  preserve: true
  model: local-llama
  in:
    question: $question
  out:
    answer: $answer
```

## Package request

Zinc sends YAML to stdin:

```yaml
surface: openai-responses.responses
model: local-llama
in:
  question: What is Zinc?
out:
  answer: $answer
```

Zinc recursively resolves `$value` references in host fields before sending the request.

## Package response

Package stdout is YAML with requested local names as top-level fields:

```yaml
answer: |
  Zinc runs package surfaces from Circuitry value flow.
```

Zinc maps only requested outputs. Missing requested outputs fail the entry.

## Run history

Zinc stores package records and run history in `~/.zinc/zinc.db`.

Core history tables:

```text
runs(id, current, meta)
steps(id, run, body)
packets(id, step, bytes)
```

`runs.current` points at the current step. `steps.body` is YAML describing one ready wave. `packets.bytes` stores YAML request/response bytes.

## Boundary

```text
Circuitry = reusable YAML value boundaries
Zinc     = environment-native execution, package records, run history
Packages = extension surfaces and package-owned meaning
```
