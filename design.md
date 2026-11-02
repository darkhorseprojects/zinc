# Zinc design

## Ownership

Portable Agents loads trusted modules, provides ordinary command-backed imports and
carries bounded bytes across a process boundary. Zinc owns execution, binding images, history, memory and Git checkpoints.
Connector owns identity, authorization, admission, presentation, delivery and provider credentials. Zinc owns inference
protocols, not provider identities; URLs, discovery, capabilities and wire settings are configuration.

Each persistent agent has its own canonical directory, ac.yaml, history database,
world repository, Connector ledger and Discord bot credential. Only immutable
versioned packages and assets are shared. Temporary computation uses `:persist false`
within an existing instance: execution records and world images stay in RAM, with a
read-only prefix of existing history. It does not create or initialize a directory.
Temporary descendants remain in memory; durable callers can retain returned results
and their own budget counters. External effects remain external.

## Source boundaries

`zinc.md` declares the application contract, bindings and exported entries. The source
modules own domains, not separate read and write layers:

- `engine.janet`: admission, workers, inference coordination, application frames and read-only observation.
- `schema.janet`: configuration/input validation and saved-grant authorization.
- `store.janet`: SQLite layout, journal operations, call ownership, fencing and stored results.
- `world.janet`: native evaluation, binding images, Git checkpoints and temporary image storage.
- `model.janet`: discovery, effective model permissions, budgets, admissions and committed inference outcomes.
- `provider.janet`: exact request encoding, provider transport and complete-response normalization.
- `memory.janet`: retrieval, compression, expansion and recorded-context inspection.
- `io.janet`: bounded subprocesses, HTTP and configured filesystem/HTTP/process operations.

Observation is private to the engine and receives a read-only connection; file placement
is not an authority boundary. Recovery coordinates Git save reconciliation, call-state
recovery and world-file materialization in that order. Temporary recovery touches only
its RAM call state. SQLite definitions stay with the store, and Git operations stay
with the world; neither depends on the other through callbacks.

## Worlds

The instance head is the latest successfully published durable root image. A call
has its own branch head. Model tools share one world within a batch; explicit
self children fork snapshots and never merge implicitly. Explicit revisions stay
pinned. Ordinary queued roots refresh from the instance head when execution starts. One durable root owns the world at a time,
including while waiting for children.

Janet binding graphs, including vars, functions, macros, closure state, mutations,
aliases and cycles, are native images. Initializers execute once, not on loading.
The authorized evaluator base is rebuilt and resolved through an image registry;
credentials, channels, I/O and invocation configuration are not world state.
Unsupported values fail snapshotting. Images require a matching format and runtime.

A batch candidate remains private until all scripts and their native descendants
settle successfully. The executor publishes its image and tool results in one
transaction. A script failure cancels the batch and discards only that candidate.
Direct code is a batch of one. Shared mutable writes are not isolated transactions;
order dependent work explicitly. Cancellation retains earlier publications. Neither
rolls back external effects. A save is an explicit Git checkpoint, not a prerequisite for
retaining successful work. SQLite's descriptor is authoritative; Git holds pinned
immutable image blobs. The worktree image is a checkpoint artifact, not another head.

`world/view` reports Janet definition forms for live bindings, image identity,
checkpoint and dirty status. Source is provenance, never executable persistence;
initializers do not replay. Images without
recorded source require explicit annotation, not decompilation or guessed code.
`world/save` commits. Save, discard and switch require an exclusive single-script
batch with no background fibers. `world/discard` and `world/switch` replace the
environment and end the evaluation. `world/remove` deletes a binding; assigning nil
does not.
The external world entry uses the same operations as evaluated Janet.

`world-bytes` limits serialized state, not heap memory. Use OS confinement for
hostile workloads. `source-bytes` limits submitted code. Zero means unlimited only
on fields explicitly marked as such; leases and shutdown bounds remain finite.
The default PRNG is entropy-seeded per invocation. Persist an explicit `math/rng`
object for continuing deterministic random state.

## Calls and grants

Direct user code and tool code use identical publication rules and language
bindings. Named filesystem, HTTP, process and trusted module grants are checked by
the host on every invocation. Native syntax is not unrestricted host authority.
Use `self` for independent child work. It yields the calling fiber; native `ev/spawn`
and `ev/gather` provide background and joined concurrency within a batch. Each
script runs in a native fiber in the shared evaluator; yielding host calls allow
other scripts to proceed. Native descendants settle before snapshotting and do not
survive model rounds. Output and host-operation admissions retain their originating
script coordinates. Subsequent batches load the last publication without replaying
initializers. Fibers/channels are runtime state, not restartable images. Self
children commit independently; caller failure does not undo their publications.
Children share budgets and deadlines. The parallel setting limits independent
calls rather than shared-world fibers.
Waiting releases execution capacity, not world ownership. Runtime `repl` settings
select bindings and explicit `repl.imports`; a separate flat host catalogue defines operations and
resource permissions. Schema `visible`/`public` annotations expose only selected
settings and granted resource metadata. Trusted setup runs once per script and
must provide independent mutable parsers.

Configured peer aliases are callable bindings, for example `(research request)`.
They invoke the target's public self entry under the target's own configuration,
database, world and credentials. Peer access requires reciprocal explicit trust;
source code cannot choose arbitrary directories or override target grants.
Cross-agent coordinates retain caller identity. Synchronous peers use `queue: false`:
start and claim share one transaction, or the request finishes with `AgentBusy`.
Rejected IDs cannot execute later. Nonqueued work never retries automatically;
explicit resume must also acquire ownership immediately. No peer waits for another
root's world ownership, so no distributed wait graph or ancestry list is needed.
Persistent targets render through their own bots; temporary computational agents
render under the invoking bot and mark their output temporary.

## Observation and memory

Committed visible reasoning and parallel tool traces are retained. Presentation
coordinates identify agent, request, run, branch and caller. Delivery intents and
receipts prevent automatic repetition of uncertain external effects. Known rendered
Discord history carries presentation provenance rather than masquerading as user
conversation. Explicitly created messages have separate provenance. Application stdout
is the only presentation input; import calls carry arguments and operation coordinates,
never presentation frames or scope identities.

Durable executors run in task workers and write only execution state and outcomes.
The initial self entry admits work and becomes a read-only observer; it does not
execute the call. Observation opens SQLite read-only, polls committed events with a
sequence cursor, and emits admission receipts separately from presentation. It never
recovers, claims, launches, executes, heartbeats, checkpoints or changes deadlines.
Chat Completions uses JSON responses. Responses uses SSE only to capture the terminal
response object; partial text and tool-call deltas are not assembled. The provider
normalizes the final message, finish reason and usage before model validation and
publication. HTTP progress callbacks enforce fencing independently of response chunks.
No provider previews are written. An expired lease is reported for inspection.

Temporary execution uses a native executor thread and a named in-memory SQLite
database, observed through another read-only connection. PA isolates protocol writes
on an I/O thread. Executor completion cancels observation and closes the RAM database
before draining any trailing presentation; no observer acknowledgement gates execution.
Temporary images never enter Git. Temporary execution cannot reattach or recover.

Execution owns publication and completion. Observation or presentation failure after
an invocation attempt detaches without revoking request authority or implicitly aborting
work. Durable reattachment reads the same journal and uses delivery receipts without
replaying completed code. Connector retains its own delivery intents and receipts, not
execution outcomes or duplicate execution diagnostics. Explicit abort cancels linked
work, not unrelated agents; a temporary worker can be terminated only while its owning
Connector process still holds its handle.

Admissions prove acceptance, not execution. An admitted inference without an outcome is never automatically resubmitted;
provider usage may already have occurred. Compaction runs only when context requires it, not speculatively after answers.
Stable instructions and memory precede changing world state. Responses replay retains encrypted reasoning and native
items for the same model while all context selection and tool execution remain local. Inspect original outcomes before
repeating uncertain work. `memory/expand` exposes bounded original records.
The `views` and `render` entries use one recorded-prompt projection across protocols.
Views reports chronological and semantic windows and a composition bar; its summaries
mode shows used source trees, ranges, depths and invalidations. Render includes readable
messages and the exact recorded request. Selected original images share a bounded
prompt image budget, with current inquiry images first and omissions labeled. Source submissions remain in event history, not in
executable persistence. Historical images do not grant historical authority.

## Janet documentation

Use Janet's own documentation, available inside the evaluator:

    (doc math/rng-int)
    (doc "string/")
    (doc-of string/join)

`doc*` is the functional documentation interface. `describe` prints a value's
representation, not its usage. Do not use Clojure spellings such as `concat`,
`println` or `str`; consult the native binding documentation instead.
