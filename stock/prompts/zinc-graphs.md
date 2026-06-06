# Zinc graphs

Zinc runs Circuitry `0.5` graphs. A graph is explicit YAML: exports declare callable entry points, resources declare named values/effects, and model resources list exactly what context and tools the model receives.

Core shape:

```yaml
circuitry: "0.5"
title: Example

exports:
  main:
    run: assistant
    input:
      user_turn: string

resources:
  guide:
    text:
      uri: prompt:bash-guide

  assistant:
    model:
      identity: Zinc
      input:
        - $user_turn
        - guide
      tools:
        - read
        - bash
      instructions: Answer directly.
```

Zinc materializes these resource kinds:

- `text`
- `data`
- `file`
- `run`
- `model`

Circuitry owns graph validation, imports, exports, addresses, schemas, reachable input discovery, and dependency planning. Zinc owns runtime effects: URI materialization, model endpoint calls, tool execution, packages, sessions, and permissions.

Important rules:

- Model `input` is the complete visible context list. Nothing else is implicitly included.
- Model `tools` is the complete callable tool list. Tools are unavailable unless listed.
- Provider details belong in Zinc config, not graph files.
- Use export inputs (`$name`) for request-specific values.
- Use imports for reusable modules.
- Use `run` resources for known child graph calls.
- Use `run_graph` only when the model needs to choose a graph dynamically at runtime.
- Use `schema` on `model` or `run` resources when output shape matters.
- Validate before running with `zn check`.

Local package installs may patch `.zinc/graphs/zinc-loop.circuitry.yaml` and import `.zinc/generated/packages.circuitry.yaml`. Generated package imports should remain visible and reviewable in graph source.
