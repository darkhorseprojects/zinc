# 0.3.0

Configuration is declared explicitly with descriptions and one index of existing
optional capabilities. Context defaults to provider capacity unless capped by
the operator; automatic output uses the remaining provider capacity. Saved caps
remain effective. Explicit provider reasoning requirements and effort lists are
validated before completion requests.

One schedulable call owns execution, admitted history and its source snapshot.
Separate run, branch, task and driver records are gone. The inquiry-v3 contract
retains semantic terminal results and emits application-owned start/display
envelopes.

Durable call controls retain deadlines, shared quotas, ownership and
cancellation. Persistent payloads use the main database; temporary inputs,
checkpoints, events and outcomes use a bounded attached RAM journal. Temporary
snapshots do not copy execution authority.

Input events and model outcomes are canonical. Conversation, memory, emitted
turns and terminal results project those records rather than copying answers or
adding response/completion markers. Code results retain their value and failure
trace in one completion receipt. Quota failures record terminal outcomes rather
than stranding completed work; saving earlier calls rechecks file identity.

Generation fencing guards effects. A unique attempt receipt excludes duplicate
executors without allowing the rejected executor to finish another executor's
claim. Original owners may record known model completions after cancellation or
uncertainty, but not after replacement by a new generation. Waiting releases
capacity, including at one slot; completing a root does not revoke accepted
descendants.

Checkpoints retain semantic evidence, summary frontier/source position and
pending model requests. Evaluators are created lazily on first code execution;
resolved capability bindings belong to the executing call. Administrative
exports do not eagerly load unrelated capabilities or model assets.

The history schema resets to version 1. Preserve pre-reset stores and provision a fresh
path; there is no migration or compatibility adapter. Cygnet runtime assets
remain format 1, with their provenance and licenses retained.

Chat and rerank share one admission/accounting lifecycle. HTTP and heartbeat
workers receive only their operation inputs. Images are decoded once and replay
identity compares bytes; history range defaults resolve before grant validation.
Matching PA protocol-2 binaries, SDKs and consumers are required.

CI exercises real installed PA discovery, replay, private execution, passive
records, recursive scheduling, duplicate executor fencing, descendant handoff
and summary compaction.
