# Zinc

Zinc is a tiny local runtime for Circuitry graphs.

Circuitry describes topology.
Zinc runs it.

Prompts are inputs.
Tools are runtime functions.
Graphs are executable topology.

```bash
zn "inspect this repo"
```

Zinc provides:

- local model loop via OpenAI-compatible provider
- read/write/edit/bash tools
- sessions with semantic JSONL logs
- prompt packages with frontmatter
- graph-run requests with approval policy
- local model serving via llama.cpp

## Default graph

```yaml
circuitry: "0.4"
entry: assistant
inputs:
  user_turn:
    type: text
    required: true
resources:
  user_turn:
    type: input
    from: user_turn
  assistant:
    type: agent
    identity: Zinc
    inputs: [user_turn]
    tools: [read, write, edit, bash, run_graph]
outputs:
  response:
    from: assistant.response
```

## Install

```bash
npm install -g @darkhorseprojects/circuitry
./scripts/install-linux.sh
```

## License

Apache-2.0.