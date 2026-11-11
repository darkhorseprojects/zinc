# Zinc

Zinc owns Janet execution, effects, queued work, memory and native image-based worlds. Its host owns the process
lifetime. Connector supplies transport, credentials and external capability imports, not a second work scheduler.

```text
append information ──► source history only
queue information  ──► admitted work ──► eligible when its lane is available
self(request)       ──► admitted work ──► eligible immediately within configured limits
                              │
                         engine.janet
                         /          \
                 inference          janet.janet ──isolated VM + native fibers
                         \          /                  │
                           effects ◄──journaled host calls
                              │
                     committed events/outcomes ──PA──► Connector
```

## Installation

Use Janet 1.42+, JPM, a C compiler, OpenSSL headers and trusted CA certificates, Python 3.11+ and Git. PA is installed
independently as a normal Janet package; Zinc declares it as a dependency and imports `pa`. PA owns framing and
envelopes. Zinc contains no duplicate frame codec.

Install packages into JPM's configured system or user prefix, independently of Connector. For a source checkout,
`jpm deps` installs declared dependencies into that configured prefix. SQLite must support FTS5, URI filenames and
memdb:

```sh
JANET_SYSTEM_SQLITE=0 jpm --cflags=-std=c99,-DSQLITE_ENABLE_FTS5,-DSQLITE_USE_URI=1 deps
jpm run tls
jpm run assets
```

MSVC flags are `/nologo,/MD,/DSQLITE_ENABLE_FTS5,/DSQLITE_USE_URI=1`. Jsec uses `VCPKG_ROOT` on Windows and
`OPENSSL_PREFIX` for nonstandard macOS installations. The existing `tls` task rebuilds the pinned native dependency with
its cancellation cleanup fix. Set `JANET_PATH` to your configured JPM module directory when it is not the runtime
default. No application searches a sibling checkout for PA at runtime.

Install Connector separately, provision `ac.yaml`, and initialize a fresh store with `agc init DIRECTORY`.
`examples/models.ini` is an optional external model-server preset; Zinc neither provisions that server nor reads or
verifies its model downloads.

## Host and contract

`src/main.janet` accepts a live Portable Agents version-1 connection on stdin/stdout. `PA_FRAME_BYTES` bounds envelopes.
Requests carry `input`, `config` and capability `imports`; readiness is connection-wide, responses correlate by call ID,
and committed presentation is asynchronous. No one-call/EOF compatibility mode exists. `describe` advertises the normal
`self` import entry and available operations.

- `self(request)` admits `text` or `code` and returns a handle, not completion.
- `append(records)` adds authenticated, non-actionable information without invoking an agent; native Janet uses
  `self/append`.
- `queue(request)` admits actionable work without inquiry replacement; native Janet uses `self/queue`.
- `status(handle)`, `wait(handle)`, `cancel(handle)` inspect, await or cancel work.
- `memory/summarize`, `memory/expand`, `memory/invalidate` provide the same memory semantics to commands, Janet and
  imported agents.
- `init`, `resume`, `instructions`, `models`, `work`, `world`, `views`, `render`, `diagnostics` and `resolve` retain
  initialization, host continuation, inspection and explicit uncertain-effect resolution.

Connector imports a deployment by its configured name: `(research request)`, not `(research/self request)`. Related
operations are `research/wait`, `research/status` and `research/cancel`. Connector reuses the live connection and the
target's directory, configuration and grants. There is no additional proxy service, router, generated forwarding module
or detached executor.

Immediate inquiries replace eligible unfinished inquiries in their member/policy/channel lane. Queue admissions do not
replace them. Direct Janet code is independent. Source positions fence late admissions; a temporary position
participates only in host RAM. Persistent direct scripts can notify an active same-author inquiry without becoming its
descendants. `pending-requests` bounds admitted roots; `parallel` bounds concurrent effects, inquiries and summaries
separately. Waiting scripts do not consume their children's execution slots.

## Concurrency and cancellation

The existing engine is the sole work scheduler. Active ownership is RAM state, not SQL leases. Existing claim rows
retain source progress and waits; no lease is acquired or renewed. The SQLite schema and its number are unchanged. One
execution host must own a deployment/store at a time. Idle schedulers release their timers; the live process retains its
RAM sessions without continuing an idle work loop.

Each execution worker runs independently; each script has an isolated evaluator thread with Janet's native fibers,
channels and timers. Host calls become independently scheduled operations. A call suspends only its calling fiber. A
root return neither gathers nor cancels siblings, effects or descendants. Explicit `self/wait` waits for a descendant's
root outcome, not VM drain or world publication.

```janet
(ev/go (fn [] (discord/add-reaction ((discord/context) :message) "👋") nil))
(ev/go (fn [] (discord/add-reaction ((discord/context) :message) "✨") nil))
(print "Reactions started")
nil
```

Model responses admit sibling scripts and their receipts atomically. Each effect commits its own outcome and wakes
waiting execution immediately. Blocking custom bindings do not run on the host's scheduling loop. Native output
callbacks coalesce writes by port, schedule publication, and flush before host calls and root returns. Whitespace-only
output is omitted. Structured `print` values use JSON; explicit `string` conversion retains Janet semantics. Native
return values that are not JSON receive Janet-type descriptors.

Cancellation fences commits and interrupts cooperative execution; it cannot undo an external effect or forcibly
interrupt arbitrary CPU-bound/native code. Connector closes the host connection on exit and may terminate the process
after `stop_ms`. Zinc exits immediately on stdin EOF, including when Connector is lost while an evaluator is
uncooperative. Persistent work then follows interruption recovery; temporary sessions disappear. An observation timeout
alone is not a work-cancellation request. No external effect or disconnected RPC is silently retried.

## Failure and replay

Admission commits before dispatch. Explicitly persistent effects and source progress survive ordinary SQLite
persistence. On a later host start, undispatched work may execute; a dispatched effect without an outcome is uncertain.
Its operation identity, attempt, arguments and source remain available.

Use `effect/resolve` or the direct `resolve` entry to record a verified value/error, or approve a retry, with evidence.
Only the latest unresolved attempt can be resolved. Retry retains the logical effect identity. Evidence is an
attestation, not an independent verifier. Definitive failures retain their originating diagnostics; a potentially
mutating dispatch is not classified as definitely unperformed.

Interrupted Janet VMs retain completed source-form progress but not locals or native waits. Zinc never replays their
original source to reconstruct a continuation. Recovery inquiries inspect committed evidence and construct only
remaining work. Without inference authority, uncertainty stays inspectable instead of expanding grants. Interrupted
model turns continue from committed evidence; uncommitted provider tool calls are never admitted. Chat Completions and
Responses retain their provider-native reasoning replay.

## Memory

One implementation serves commands, native Janet and agent imports:

```janet
(memory/summarize start end "The actual summary text")
(memory/expand point-or-summary)
(memory/invalidate point-or-summary)
```

Bounds are inclusive source event IDs within granted history; omitted bounds select that history's current range.
Supplied text is stored unchanged as the summary, never interpreted as generation instructions. Without text, the
existing summary profile generates it. `summary: {chat: ..., thinking: ...}` overrides those chat settings. Automatic
compaction uses the same summary cache, source membership and invalidation.

Expansion recursively resolves a summary to its original source records and returns their stored source text without
headers, paraphrasing or regenerated content. It is not prompt rendering. An oversized response fails explicitly rather
than truncating source. Invalidation targets the summary or the most recent applicable summary covering a source point,
and invalidates dependent ancestors. Unrelated branches remain valid. No old standalone invalidate entry, byte-offset
expansion interface or compatibility aliases remain. Omitted command points select the latest source/summary.

Context retains bounded UTF-8 source pages and lazy binary summary branches. Closed replay prefixes use the same
pipeline; unresolved work remains exact and recent exchanges keep committed order. Explicit summaries participate in
context selection. Summaries use text-only completion, without tools or web search, and must shrink their sources when
generated automatically.

Retrieval searches authorized originals not already present verbatim. Scoped FTS, concept expansion and fuzzy terms
produce deterministic excerpts; configured reranking selects evidence within the same memory budget. Identical
query/model/excerpt manifests reuse rerank results. Scores are provider scores, not probabilities. Inclusion, cutoff and
budget decisions remain recorded.

`context-percent` defaults to 50, applied to the smaller provider window and configured `context-quota`. Instructions,
tools, world source, inquiry and live exchanges consume that budget before history and retrieval. Estimates are not
exact provider token counts; image costs are provider-dependent. Models with `output-field: none` cannot have a provider
token limit enforced by Zinc.

`/views` and `/render` retain actual prompt composition, summary sources, retrieval decisions, usage and exact requests.
Omitted points select the latest chat prompt; model results select their admission, and other events select the nearest
related prompt explicitly. Expansion remains separate from these views.

## Worlds and grants

Scripts restore native world environments without rerunning initializers. Definitions, macros, closures, mutations,
shared references and cycles persist through native images when supported. Fresh host bindings, ports and invocation
accessors are rebound; old capability connections are not restored. Unsupported reachable values fail publication rather
than being discarded.

Successful changed environments publish only after their fibers settle, against the revision they loaded. Conflicting
images remain inspectable artifacts without replacing the head, merging or replaying effects. An unchanged environment
publishes nothing. `world/remove` removes a local binding by symbol. World source shows complete recorded defining
forms, not current mutable heap values or a replay program.

`/world rewind` requires direct-execution authority, advances the world's epoch and fences unfinished old work. It does
not undo effects or erase history. Branch configuration initializes a world once. Worlds are not separate memory
security boundaries. Existing native runtime/ABI checks, authority snapshots, history ranges, quotas and resource grants
remain enforced.

Temporary work uses bounded RAM databases with inherited history/world images. Descendants inherit that storage
boundary. Temporary admissions, summaries, outcomes and metadata are never copied back to a persistent database. They
disappear with the host; explicit external effects are not made temporary or undone. This is not an OS memory sandbox.
Filesystem grants reject observed links/traversal but do not provide race-safe confinement against another process
mutating directories. TLS verifies certificates and hostnames; HTTP follows no redirects. Custom setup/modules remain
trusted configuration.

Deploy PA, Zinc and Connector together after finishing/cancelling old work. Preserve the existing database and store
identity; there is no schema-number or release-number bump, automatic image conversion or legacy execution mode.
Connector's old SQL transport state requires its documented offline cutover.
