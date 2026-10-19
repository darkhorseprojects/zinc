# 0.3.0

Temporary executors use the task scheduler's lease, parking, heartbeat and cancellation rules. Their durable task rows contain control metadata only; inputs, checkpoints and outcomes remain in the bounded RAM journal.

Model outcomes are stored once. The canonical history projection resolves branch responses to those receipts. Emitted model frames carry the assistant message rather than duplicated content/reasoning fields.

All exports share one configuration, request and cleanup boundary. Discovery advertises `inquiry-v1`, exposed parameter defaults and explicit profile metadata instead of the complete application schema.

Child calls inherit frozen source provenance without rediscovering Git state. Alternate-index operations use the same bounded Git runner. Saved profiles exclude provider tokens and private capability configuration; reauthorization retains newly imposed native restrictions.

Evaluator and memory-expansion return values are fixed. REPL cleanup no longer closes the supervisor channel before its worker finishes. Event pagination no longer shadows the core identity function.

The history store is schema version 2. Preserve old stores and provision a fresh path; there is no migration or compatibility adapter. Cygnet runtime assets remain format 1.
