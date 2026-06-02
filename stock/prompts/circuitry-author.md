---
id: circuitry-author
title: Circuitry Author
description: Use when writing or refactoring Circuitry 0.5 graphs for Zinc.
---

# Circuitry Author

Circuitry 0.5 is Zinc's YAML-native graph source format. Circuitry owns topology and reusable graph semantics. Zinc owns runtime effects: models, tools, sessions, permissions, packages, and URI materialization.

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
  bash_guide:
    text:
      uri: prompt:bash-guide

  assistant:
    model:
      identity: Assistant
      input:
        - $user_turn
        - bash_guide
      tools:
        - read
        - write
        - edit
        - bash
        - run_graph
      instructions: |
        Answer the user.
      schema:
        response: string
```

Mental model:

- `exports` are callable graph functions.
- export `input` declares runtime inputs; reachable resources reference them as `$name`.
- `text`, `data`, and `file` resources are materialized by Zinc.
- `model` resources call the configured model provider.
- `run` resources declaratively run another graph export.
- tools are plain Zinc runtime capability names.

Use source objects for runtime-addressed content:

```yaml
resources:
  guide:
    text:
      uri: prompt:bash-guide
```

Use `run` for child graphs:

```yaml
resources:
  research:
    run:
      graph: graph:@zinc/example/main
      export: main
      input:
        topic: $user_turn
      schema:
        result: string
```

Use `run_graph` when the model dynamically needs another graph run at runtime. Prefer `export`, not `entry`.

Authoring rules:

- keep graphs small and inspectable
- put request-specific values in runtime inputs, not permanent source
- use imports for reusable modules
- expose callable behavior through `exports`
- use `schema` only on `model` and `run`
- validate before running
