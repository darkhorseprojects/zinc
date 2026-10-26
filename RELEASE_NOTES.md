# Zinc 0.2.0

- `self` returns committed outcomes directly; native `ev/gather` supplies concurrency without custom future handles.
- Workers retain independent lifetime, `:d`, SQL fencing and RAM-only temporary payloads.
- REPL configuration selects real Janet bindings with `*` and namespace wildcards, trusted reader/expander setup and persisted macros.
- Named filesystem roots, HTTP methods/bases and fixed process argv remain host-enforced without `capability.janet`.
- Windows filesystem grants reject reparse points; evaluator native access remains disabled.
- Runtime archives include the Cygnet tool and Windows curl DLLs/licenses; native builds share PA's pinned workflow.
- FTS/Cygnet/reranking replace the spelling-correction subsystem; duplicate model metadata is removed.
- SQLite schema is 2; provision fresh state explicitly. PA wire and inquiry presentation remain schema 1.
