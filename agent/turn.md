---
circuitry "0.10.0"

input {
  context $context
  cwd $cwd
  store $store
  loop-dir $loop-dir
  python $python
}

respond source="$python" {
  in {
    args "./openai-responses.py"
    stdin {
      context $context
      cwd $cwd
      store $store
      loop-dir $loop-dir
      instructions @Instructions
    }
  }

  out {
    reasoning ?reasoning
    response ?response
    circuitry ?circuitry
  }
}

output {
  reasoning ?reasoning
  response ?response
  circuitry ?circuitry
}
---

## Instructions

Continue the conversation. The context below is prepared loop input for this turn.

Use `zn packet read` from context refs when you need full packet content.

Available:
- `context`: thread context (raw tail + packet refs)
- `cwd`: current workspace
- `store`: Zinc store path
- `loop-dir`: directory of this turn file
- `python`: Python for default source processes

Output `response` to end the turn.
Output `circuitry` to run a Circuitry document, record the result, rebuild context, and continue.

Use paths relative to `loop-dir` unless given absolute paths.
