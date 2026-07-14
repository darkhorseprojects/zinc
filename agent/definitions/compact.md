---
in {
  candidates $candidates
  context $context
  completions-url $completions-url
  token-limit $token-limit
  compact-at $compact-at
  tokens-left $tokens-left
}

compact source="$completions-url" {
  (json)in #"""
  {
    "stream": true,
    "stream_options": { "include_usage": true },
    "messages": [
      { "role": "system", "content": "@Compaction" },
      { "role": "system", "content": "Current context:\n$context\n\nOrdered context candidates:\n$candidates\n\nToken capacity: $tokens-left of $token-limit tokens remain. The configured compaction threshold is $compact-at percent." }
    ],
    "tools": [{
      "type": "function",
      "function": {
        "name": "apply_compaction",
        "description": "Classify every current context packet occurrence exactly once and in order.",
        "parameters": {
          "type": "object",
          "properties": {
            "decisions": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "action": { "type": "string", "enum": ["keep", "summarize", "drop"] },
                  "indexes": {
                    "type": "array",
                    "items": { "type": "integer", "minimum": 0 },
                    "minItems": 1
                  },
                  "rank": { "type": "number", "minimum": 0, "maximum": 1 },
                  "content": { "type": "string" }
                },
                "required": ["action", "indexes", "rank"],
                "additionalProperties": false
              }
            }
          },
          "required": ["decisions"],
          "additionalProperties": false
        }
      }
    }],
    "tool_choice": { "type": "function", "function": { "name": "apply_compaction" } }
  }
  """#

  (json)out #"""
  {
    "choices": [{
      "delta": {
        "tool_calls": [{ "index": "?call", "function": { "arguments": { "decisions": "?decisions" } } }]
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
  compaction $decisions
  prompt-tokens ?prompt-tokens
  completion-tokens ?completion-tokens
  used-tokens ?used-tokens
}
---

## Description

Required operation for a `compact` turn event: rank and compact the current ordered context packet ranges.

## Use

Invoke this exact nested source shape and expose its result unchanged:

```kdl
in {
  compact-candidates $compact-candidates
  context $context
  completions-url $completions-url
  definitions $definitions
  token-limit $token-limit
  compact-at $compact-at
  tokens-left $tokens-left
}

compact source="$definitions/compact.md" {
  in {
    candidates $compact-candidates
    context $context
    completions-url $completions-url
    token-limit $token-limit
    compact-at $compact-at
    tokens-left $tokens-left
  }
  out {
    compaction $compaction
    prompt-tokens ?compact-prompt
    completion-tokens ?compact-completion
    used-tokens ?compact-used
  }
}

out {
  compaction $compaction
  prompt-tokens ?compact-prompt
  completion-tokens ?compact-completion
  used-tokens ?compact-used
}
```

## Compaction

Classify every supplied candidate exactly once and in its existing order.

Keep high-value ranges verbatim. Combine only adjacent medium-value context ranges into a faithful Markdown summary. Preserve concrete decisions, constraints, unfinished work, errors, paths, and references required to continue. Drop low-value ranges that no longer contribute to likely unfinished work.

Candidates are zero-indexed in the supplied order. A `keep` or `drop` decision contains exactly one candidate index. A `summarize` decision may contain several adjacent indexes and must include non-empty Markdown `content`. Classify indexes in ascending order without omission or repetition. Zinc maps indexes back to exact packet/range occurrences, preserving order and duplicates. Rank expresses current relevance from zero to one; Zinc stores sources and summaries, not ranks.
