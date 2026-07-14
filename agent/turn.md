---
in {
  context $context
  thread $thread
  packets $packets
  compact-candidates $compact-candidates
  event $event
  completions-url $completions-url
  shell $shell
  cwd $cwd
  allowlist $allowlist
  definitions $definitions
  available-definitions $available-definitions
  token-limit $token-limit
  compact-at $compact-at
  prompt-tokens $prompt-tokens
  completion-tokens $completion-tokens
  tokens-left $tokens-left
  session-tokens $session-tokens
}

respond source="$completions-url" {
  (json)in #"""
  {
    "stream": true,
    "stream_options": { "include_usage": true },
    "messages": [
      { "role": "system", "content": "@Instructions" },
      { "role": "system", "content": "Workspace: $cwd\nShell: $shell\nAllowed commands: $allowlist\nDefinitions directory: $definitions\nTurn event: $event\nContext capacity: $tokens-left of $token-limit tokens remain. Session usage: $session-tokens tokens.\n\nAvailable Circuitry definitions:\n$available-definitions" },
      { "role": "system", "content": "@Circuitry" },
      { "role": "system", "content": "$context" }
    ],
    "tools": [{
      "type": "function",
      "function": {
        "name": "circuitry",
        "description": "Execute a complete Circuitry dataflow. Root inputs include context, thread, packets, event, definitions, provider and token bindings. Sources may be identity, HTTP, processes, or nested .md/.kdl definitions. Every decoded document is data and EOF completes a source.",
        "parameters": {
          "type": "object",
          "properties": { "kdl": { "type": "string", "description": "A complete Circuitry document." } },
          "required": ["kdl"],
          "additionalProperties": false
        }
      }
    }]
  }
  """#

  (json)out #"""
  {
    "choices": [{
      "delta": {
        "reasoning_content": "?reasoning",
        "content": "?response",
        "tool_calls": [{ "index": "?call", "function": { "arguments": { "kdl": "?circuitry" } } }]
      }
    }],
    "usage": {
      "prompt_tokens": "?prompt-tokens",
      "completion_tokens": "?completion-tokens",
      "total_tokens": "?used-tokens"
    }
  }
  """#
}

out {
  reasoning ?reasoning
  response ?response
  circuitry ?circuitry
  prompt-tokens ?prompt-tokens
  completion-tokens ?completion-tokens
  used-tokens ?used-tokens
}
---

## Instructions

Perform only the operation named by the supplied turn event. A `respond` event means complete the current request normally. Any other event exposes its required definition in the available-definition list; invoke that definition exactly as documented and expose its result without a user-facing response.

Continue authorized implementation and verification. Ask only when a required decision is missing or an unapproved destructive action would be necessary.

Older visual and context material is available through the normal `packets` input. Inspect that binding through Circuitry when needed. Read exact content through the allowed shell with `zn packet read --packet ID` or `zn packet read --packet ID --from N --to N`; ranges are zero-based and half-open.

## Circuitry

Circuitry describes dataflow through bindings. Ready entries run in declaration-order generations, independent entries may run concurrently, and nested `.md` or `.kdl` sources call reusable definitions. Sources may be identity, HTTP, processes, or nested Circuitry. Ports explicitly use KDL, JSON, text, or bytes. Every decoded source document is data; EOF or process exit completes the source. Import required values through root `in` and expose useful results through root `out`.

A final root `response` completes an ordinary turn. Root `definition` creates a reusable definition with a filename-safe `name` and complete KDL-fronted Markdown `document` containing `Description` and `Use` sections. A packet-read action returns root `packet`, optional `from` and `to`, and `content`.
