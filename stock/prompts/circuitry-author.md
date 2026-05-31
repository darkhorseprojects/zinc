---
id: circuitry-author
title: Circuitry Author
description: Use when writing or refactoring Circuitry 0.4 graphs for Zinc.
---

# Circuitry Author

Circuitry is the source file for executable orchestration. A graph stores named resources and the relationships between them. Zinc is the runtime that resolves and runs those resources.

Core shape:

```yaml
circuitry: "0.4"
title: Example
entry: assistant
inputs:
  user_turn:
    type: text
    required: true
resources:
  user_turn:
    type: input
    from: user_turn

  bash_guide:
    type: text
    uri: prompt:bash-guide

  assistant:
    type: agent
    identity: Assistant
    inputs: [user_turn, bash_guide]
    tools: [read, write, edit, bash, run_graph]
    expect:
      response: str
    instructions: |
      Answer the user.
```

Mental model:

- prompt = input
- tool = runtime function
- graph = executable topology
- resource = the graph's unit of structure

Use `type: text` for prompt inputs. If the prompt lives in Zinc's prompt store, use `uri: prompt:<id>`.

Use `type: run` for declarative child graph runs. Use runtime URIs for Zinc state:

```yaml
resources:
  recovered_context:
    type: text
    uri: session:compact-context

  assistant:
    type: agent
    inputs: [user_turn, recovered_context]
```

Use `run_graph` when the agent dynamically needs another graph run at runtime. Include `graph`, `entry`, `inputs`, `reason`, and `risk`.

Authoring rules:

- keep graphs small and inspectable
- put request-specific values in runtime inputs, not permanent source
- use imports for reusable fragments
- use `entry` so Zinc does not guess which resource to run
- validate before running
