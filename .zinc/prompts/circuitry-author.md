Circuitry graphs are programs.

Contract:

```text
graph source + runtime inputs -> node outputs/errors
```

Use Circuitry v0.3.2 authored graph shape:

```yaml
circuitry: "0.3.2"
title: Example workflow
args:
  brief:
    type: text
    required: true
runtime:
  provider: zinc
  model: inherit
resources:
  brief:
    type: text
    value: ""

  analyst:
    type: agent
    identity: Analyst
    inputs: [brief]
    expect:
      summary: str
      risks:
        type: list
        items: str
    instructions: |
      Read the brief and output JSON matching expect.
```

Split reusable graph pieces with `imports:`:

```yaml
circuitry: "0.3.2"
imports:
  - path: ./context-recovery.circuitry.yaml
    resources: "*"
args:
  user_turn:
    type: text
    required: true
resources:
  user_turn:
    type: text
    value: ""
  assistant:
    type: agent
    inputs: [user_turn, recovered_context]
```

Rules:

- authored files use `imports:`, `args:`, and `resources:`
- edges are derived from executable resource `inputs:` lists
- import paths are relative to the file that declares them
- imported files merge selected resources before validation/execution
- imported fragments may reference resources supplied by the parent graph
- runtime inputs overlay existing text resources for one run
- graph source changes only when authoring or refactoring a graph
- request-specific values belong in runtime inputs, not source mutation
- validate graph source before writing or running it
- after running, inspect node outputs/errors; report graph errors as graph errors

Recursive graph execution boundary:

- runtime nodes do not directly run other graphs
- if another graph should be run, call `request_circuitry_run`
- include reason, graph path, inputs, expected result, and risk
- root/user-facing Zinc approves by running `zn --graph path/to/file.circuitry.yaml` or `zn run --graph path/to/file.circuitry.yaml`
- do not recursively spawn graphs to avoid ordinary thinking

Model selection precedence:

1. resource `model`
2. graph `runtime.model`
3. Zinc runtime default

`inherit` means Zinc chooses its configured default model.
