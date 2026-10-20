# 0.3.0

One schedulable call owns execution, admitted history and its source snapshot. Separate run, branch, task and driver records are gone. Public inquiry-v2 coordinates and exports remain unchanged.

Durable call controls retain deadlines, shared quotas, ownership and cancellation. Persistent payloads use the main database; temporary inputs, checkpoints, events and outcomes use a bounded attached RAM journal. Temporary snapshots do not copy execution authority.

Input events and model outcomes are canonical. Conversation, memory, emitted turns and terminal results project those records rather than copying answers or adding response/completion markers. Code results retain their value and failure trace in one completion receipt.

Generation fencing guards effects. A unique attempt receipt excludes duplicate executors without allowing the rejected executor to finish another executor's claim. Original owners may record known model completions after cancellation or uncertainty, but not after replacement by a new generation. Waiting releases capacity, including at one slot; completing a root does not revoke accepted descendants.

Checkpoints retain semantic evidence, summary frontier/source position and pending model requests. Evaluators and resolved capability bindings belong to the executing call. Administrative exports do not eagerly load unrelated capabilities or model assets.

The history store is schema version 6. Preserve old stores and provision a fresh path; there is no migration or compatibility adapter. Cygnet runtime assets remain format 1, with their provenance and licenses retained.

CI exercises real installed PA discovery, replay, private execution, passive records, recursive scheduling, duplicate executor fencing, descendant handoff and summary compaction.
