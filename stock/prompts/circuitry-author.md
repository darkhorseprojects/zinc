---
id: circuitry-author
title: Circuitry Author
description: Use when writing or refactoring Circuitry 0.5 graphs for Zinc.
---

# Circuitry Author

Circuitry `0.5` is Zinc's YAML-native graph format. Circuitry owns graph semantics. Zinc owns runtime effects.

Write graphs as small, inspectable runtime programs. Be explicit about inputs, tools, schemas, and child graph calls.

## Minimal model graph

```yaml
circuitry: "0.5"
title: Example

exports:
  main:
    run: assistant
    input:
      user_turn: string

resources:
  assistant:
    model:
      identity: Assistant
      input:
        - $user_turn
      tools:
        - read
        - bash
      instructions: |
        Answer the user directly.
```

## Mental model

- `exports` are callable graph entry points.
- export `input` declares runtime inputs; reachable resources reference them as `$name`.
- `text`, `data`, and `file` resources are materialized by Zinc.
- `model` resources call the configured model provider.
- `run` resources call another graph export declaratively.
- tools are plain Zinc runtime capability names.
- endpoint/provider config belongs in Zinc config, not graph source.

## Runtime text sources

Prompt resource:

```yaml
resources:
  guide:
    text:
      uri: prompt:bash-guide
```

File resource:

```yaml
resources:
  notes:
    text:
      path: ./NOTES.md
```

Runtime input:

```yaml
resources:
  assistant:
    model:
      input:
        - $user_turn
```

## Child graph calls

Use `run` when the graph call is known ahead of time:

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

Use the `run_graph` tool only when the model needs to choose a graph dynamically at runtime. Prefer `export`, not `entry`.

## Packages and imports

Local package installs may add:

```yaml
imports:
  packages: "/path/to/project/.zinc/generated/packages.circuitry.yaml"
```

Then package resources appear under the imported namespace:

```yaml
input:
  - packages.example_prompt
```

Do not hand-author generated package files.

## Authoring rules

- Keep graphs small and inspectable.
- Put request-specific values in export inputs, not permanent source.
- Declare exactly the model context needed in `input`.
- Declare exactly the tools needed in `tools`.
- Use imports for reusable modules.
- Use `schema` on `model` and `run` when output shape matters.
- Validate with `zn check` before relying on a graph.
- Do not put secrets, endpoint URLs, or provider details into graph files.
