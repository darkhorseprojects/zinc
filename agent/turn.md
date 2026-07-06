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
      context      $context
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

Continue the conversation. The context below is the prepared thread input for this turn.

Use `zn packet read` from context refs when you need full packet content.

Output `response` to end the turn.
Output `circuitry` to run a Circuitry document, record the result, rebuild context, and continue.
