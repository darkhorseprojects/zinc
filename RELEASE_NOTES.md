# Zinc 0.2.0

- `self` returns committed outcomes directly; native `ev/gather` supplies concurrency without custom future handles.
- Workers retain independent lifetime, `:d`, SQL fencing and RAM-only temporary payloads.
- REPL declarations add or replace world source; definitions evaluating to nil remove it. Other expressions do not rewrite source.
- Named filesystem roots, HTTP methods/bases and fixed process argv remain host-enforced without `capability.janet`.
- Windows filesystem grants reject reparse points; evaluator native access remains disabled.
- Runtime archives include the Cygnet tool and Windows curl DLLs/licenses; native builds share PA's pinned workflow.
- One stopword-filtered word pipeline combines exact Cygnet expansion and history-vocabulary trigrams; only the reranker scores relevance.
- Each schema-1 database binds to one Git world file. Source/world labels and cross-world visibility are removed.
- Presentation identifies world paths and source blobs; deploy matching Connector. PA wire remains schema 1.
