# Graphs

Zinc graphs are authored as Circuitry source files.

A loop graph declares runtime args and a tool-using agent:

```yaml
circuitry: "0.3.2"
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
    inputs: [user_turn]
    tools: [read, write, edit, bash]
    expect:
      response: str
    instructions: Answer the user.
```

Runtime inputs overlay resources for one run:

```bash
zn run --graph repair --text notes=@notes.md --image shot=./shot.png "fix it"
```

Graph lookup order:

1. explicit path
2. `.zinc/graphs`
3. local package graph exports
4. global package graph exports
5. stock graphs in `~/.local/share/zinc/graphs`

Use `zn check` for Circuitry graph validation. Use `zn compile` only for loop entrypoints.
