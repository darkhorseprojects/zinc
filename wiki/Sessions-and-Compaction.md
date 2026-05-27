# Sessions and Compaction

Zinc writes semantic JSONL rows under `.zinc/sessions`.

Rows represent user messages, assistant messages, tool calls, tool results, and compaction summaries. The runtime projects those rows back into provider messages when continuing a session.

```bash
zn "start work"
zn --continue "keep going"
zn --session s123 "resume this session"
```

Compaction preserves the first messages and the recent tail, then summarizes the middle through the configured compaction graph.

```bash
zn compact --dry-run
zn compact
zn compact --session s123
```

The stock loop graph imports a context-recovery fragment. That fragment is valid Circuitry, but it is not a standalone loop compile target.
