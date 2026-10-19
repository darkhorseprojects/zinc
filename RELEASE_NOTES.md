# 0.3.0

Run/task controls and execution payloads are separate. Temporary execution attaches a bounded RAM journal to the control connection, so one transaction owns control and private payload updates. Branches own history grants, depth and execution-profile selection.

All execution uses one durable task scheduler and one claim per attempt. A unique entry receipt prevents duplicate executors from consuming that claim. Temporary task inputs, checkpoints and outcomes live in the bounded RAM journal; no second scheduler or executor lease is copied into it.

Summary preparation retains an ordered binary frontier instead of separate accumulation and reduction arrays. Executing calls share resolved model profiles, and public history and emitted frames use one reasoning-visibility projection.

Model outcomes are stored once. The canonical history projection resolves branch responses to those receipts. Emitted model frames carry the assistant message rather than duplicated content/reasoning fields.

All exports share one configuration, request and cleanup boundary. Discovery advertises `inquiry-v2`, exposed parameter defaults and explicit profile metadata instead of the complete application schema.

Child calls inherit frozen source provenance without rediscovering Git state. Alternate-index operations use the same bounded Git runner. Saved profiles exclude provider tokens and private capability configuration; reauthorization retains newly imposed native restrictions.

Evaluator and memory-expansion return values are fixed. REPL cleanup no longer closes the supervisor channel before its worker finishes. Event pagination no longer shadows the core identity function.

The history store is schema version 4. Preserve old stores and provision a fresh path; there is no migration or compatibility adapter. Cygnet runtime assets remain format 1.
