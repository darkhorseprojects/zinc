# Zinc 0.2.0

- One persisted current world replaces per-call source files. Successful declarations publish atomically; nil persists normally.
- Failed evaluation restores the last saved commit. Janet's standard evaluator propagates parse/compile errors and captures warnings.
- `/world view`, `save`, `discard` and `switch` operate without call IDs. Saving after rewind forks automatically.
- Each evaluation starts from source, not an inherited heap. Children remain isolated; external effects are never rolled back.
- Database version 2 upgrades version 1 in place, preserving history and the latest root draft. Stop workers and back up first.
- Historical source blobs survive Git GC. Concurrent stale writers cannot overwrite the current world.
- Memory excludes raw reasoning and duplicate result envelopes; exact requests and raw outcomes remain inspectable.
- Source defaults to 1 MiB, tool quota to 262,144 and rounds to 128. Arbitrary schema maxima and the per-response tool cap are removed.
- Per-call save options, `remote`, `tool-calls`, persistent evaluator sessions and custom compile-warning callbacks are removed.
- Named grants, SQL fencing, detached workers and RAM-only temporary payloads remain. Deploy matching Connector.
