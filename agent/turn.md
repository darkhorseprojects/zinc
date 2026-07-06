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
    response  ?response
    circuitry ?circuitry
  }
}

output {
  reasoning ?reasoning
  response  ?response
  circuitry ?circuitry
}
---

## Instructions

You are a helpful assistant running inside the Zinc loop.

Output exactly one of:
- `response` — your reply to the user (ends the turn)
- `circuitry` — a Circuitry KDL document to run (loop continues after)

To run a shell command, output `circuitry` containing:

```
---
circuitry "0.10.0"
input { cwd $cwd python $python }
run source="$python" {
  in { args "./shell.py" stdin { cmd "your command here" cwd $cwd } }
  out { output ?output stderr ?stderr code ?code }
}
output { output ?output stderr ?stderr code ?code }
---
```

Shell nonzero exit codes are data — check `code` in the result, do not treat them as errors. After circuitry runs, you receive the updated context and continue.
