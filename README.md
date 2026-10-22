# Zinc

Zinc is a Janet agent package for Portable Agents. It owns `self`, task
execution, file-backed worlds, private history and permission profiles. It does
not depend on Connector.

There is no resident service, Unix socket, REPL relay, ledger import, Git
service or public `invoke`/`eval` operation.

## Build

Use Janet 1.42+, Jpm, system SQLite with FTS5 and development headers,
pkg-config, and the matching PA executable:

```sh
JANET_SYSTEM_SQLITE=1 jpm --local deps
jpm --local install
```

Zinc installs package sources, not an executable. Select `zinc.md` export `self`
through PA's `spawn` SDK or CLI. Supply `jpm_tree/lib` as the explicit `library`
dependency when using a checkout.

## Self and functions

Main input selects text or code. The trusted invoker supplies the authenticated
`author` and source occurrence `at`, in UTC with millisecond precision:

```json
{
  "text": "Investigate the implementation",
  "request": "stable-operation-key",
  "author": "principal-id",
  "at": "2026-01-01T00:00:00.000Z"
}
```

```json
{
  "code": "(double 21)",
  "request": "another-operation-key",
  "author": "principal-id",
  "at": "2026-01-01T00:00:00.000Z"
}
```

Inside world code:

```janet
(await (self {:text "Find the earlier decision about deployment"}))
(memory/expand event-id)
```

`memory/expand` is the only exposed memory function. It returns the requested
record's own bounded page, including ID, author, occurrence time and summary
child IDs. Follow child IDs to drill down; pass `next` as the optional byte
offset while `next < total`. It never substitutes an admission for an actual
result. Searching is an inquiry to `self`; the semantic window retrieves
originals internally.

Built-in functions are called directly. `self` admits descendant work and
returns a durable Zinc handle. `await` reads a descendant outcome. PA handles
remain separate, ephemeral observation handles.

`record`, `describe`, `document`, `models`, `events`, `pending`, `resume` and
`abort` are ordinary package exports used by invokers. `task` executes trusted
jobs; `invalidate` controls the summary cache. Neither is a world binding.
Generated environments receive neither PA spawning nor private runtime
configuration.

## Passive context

The trusted `record` export accepts
`{"records":[{"key":"external-id","author":"principal-id","at":"2026-01-01T00:00:00.000Z","text":"observed text"}]}`
and returns committed `events` IDs. Repeated identical records return the same
IDs; reusing a key with different content is an error.

Recording creates no turn, run, task, inference, code evaluation or background
summary. Even Janet fences are stored as data. Context belongs to the configured
authenticated `source` and `world`; the next new inquiry includes it within its
history bounds. Running turns retain their frozen cutoffs. `record` is not a
generated-world binding.

`source` is the history namespace, not the record author or a world filename.
Source isolation and current execution grants remain separate. Only a new `self`
inquiry asks for work or a response.

## Worlds and concurrency

Required identity is `source`, absolute `store`, and `world`. For Janet
execution, set `repl: true`, an absolute `file`, `seconds`, and native
restrictions in `forbid`.

Each complete call owns one detached executor and editable source file. Its
Janet REPL environment is created only when code first executes. Definitions and
redefinitions survive its model/tool rounds; mutations within that REPL are
sequential. Parallel selves have separate files and environments. Closing
channels does not terminate CPU-bound evaluation; hard termination requires
executor-level enforcement.

```text
admitted world entry source
          /       \
      branch A   branch B
       own VM     own VM
          \       /
        durable outcomes
           SQLite WAL
```

Root calls read the world file from Git HEAD, or an explicit `revision`. Edits
do not create commits. An untracked initial world file can seed the first
explicit save. Descendants inherit the parent's current source-file snapshot,
not its live heap. Durable parallel selves receive Git refs; no worktrees,
workspace manager or automatic heap merge are involved.

Use `(world :current-file)` to edit the call's source. Reload edited definitions
explicitly; remove a binding with `(put world 'helper nil)`. Existing closures
can retain old references. The next call reconstructs its environment from
source. `parent` and inclusive `memory_range` constrain history, independently
of source revisions.

`persist: false` keeps execution payloads in an executor-owned, bounded RAM
journal. Durable control metadata retains identifiers, deadlines, quotas,
ownership and cancellation, never temporary input/output. Temporary descendants
stay temporary, cannot be replayed or reattached, and lose their journal when
their executor dies. Their call files are removed on normal cleanup. This does
not erase parent-stored inputs, provider/Discord logs, OS swap, or explicitly
requested filesystem/Git effects. Admitted history must fit the RAM journal;
exhaustion fails explicitly rather than dropping older records. Child snapshots
retain temporary identities and do not reactivate copied historical leases.

Optional `instructions` points to a plain world instruction file. Prompt
construction reads it without executing the world merely to discover
instructions.

## Capabilities

Trusted Janet source declares interfaces through ordinary functions and their
docstrings. A profile's `capabilities` map grants access to source declarations
or library namespaces:

```janet
(defn echo
  "(example/echo text) — Return text with the provided prefix."
  [text]
  (string ((dyn :capability/config) :prefix) text))
```

Built-ins and supplied libraries use the same grant map:

```json
{
  "capabilities": {
    "memory/expand": {},
    "save": {},
    "example": {
      "module": "/runtime/example.janet",
      "config": { "prefix": "hello: " }
    }
  }
}
```

Zinc resolves granted functions once per executing call and derives bindings and
instructions from the same source metadata. Calls need no import:

```janet
(example/echo "world")
```

The runtime binds `(dyn :capability/config)` only while invoking the trusted
function outside the world. Private definitions and macros are not exposed;
public functions require docstrings. Grant and owner-generation checks still
apply to each invocation. Changing a world binding cannot manufacture authority.

The named `capabilities` table in `zinc.md` is the index of optional built-ins
and their source metadata. Adding a declaration does not grant it; profiles
still select their own capabilities. `self`, `await`, `input` and
`self/document` remain runtime intrinsics. Supplied namespaces expose documented
public functions from a protected library at an absolute path. There is no
separate registration API or synthetic import module. Libraries may cross
executable boundaries; Zinc does not know their provider.

## User and agent profiles

`inference` controls model-driven selves. The `capabilities` map grants all
exposed built-ins and supplied functions; an empty map grants none. There is no
separate `permissions` list or `save` flag.

An authorized human execution may have `inference: false`,
`capabilities: {save: {}}`, and a trusted `agent` profile. Text selves use that
agent profile; code selves retain the caller's profile. Profiles must share
source/store/world/file identity. Saved work is reauthorized against current
profiles. Removed configuration fields are rejected, not converted. Old
in-flight profiles cannot resume under a revoked contract. Store format is 1;
incompatible layouts require explicit fresh-store provisioning, not migration.

`save` is an optional built-in, limited to the configured world source file:

```janet
(save "Update world")
(save "Try another approach" {:branch "experiment"})
(save "Integrate" {:merge "refs/heads/self/BRANCH"})
(save "Keep an earlier call" {:call CALL-ID})
(save "Publish" {:push true})
```

Without `:call`, `save` operates on its executing call's world file. A later
inquiry creates another call and does not implicitly select an earlier edited
world. Saving that earlier work requires its call ID. Agents must have an
explicit `save` capability to commit their own worlds.

It initializes Git when necessary, stages new world files, creates explicit
commits and updates refs with compare-and-swap. Merges must affect only the
world file. Dirty canonical working files are preserved. Push additionally
requires a configured `remote`; arbitrary destinations and implicit force/mirror
pushes are not supported. Other files and installed Zinc sources require
separately granted native filesystem authority.

Permission bindings are not OS isolation. A world granted unrestricted native
filesystem/subprocess access can bypass logical permissions. Keep runtime
libraries immutable, protect private storage and Git metadata, scrub
credentials, and supply appropriate OS confinement. Janet's irreversible native
restrictions complement that boundary; VM separation alone is not filesystem
confidentiality.

## Work and history

SQLite format 1 separates durable call controls from execution payloads. A call
owns its admitted history, source snapshot and execution profile; public run and
branch coordinates are projections, not separate execution identities. Temporary
executors attach a bounded RAM journal to their control connection and use the
same transaction and scheduler rules without storing private payloads durably.
Every event retains an author, source occurrence timestamp and separate
ingestion clock. Accepted execution can finish and commit after its PA observer
dies. It cannot survive death of its own executing process or OS scope.

`parallel` bounds running tasks; waits release and reacquire slots, including
recursion at one slot. `task-depth`, `task-quota` and the admission-anchored
`run-seconds` bound work. Reattachment never resets deadlines. Code and
arbitrary capability effects are manual-recovery work, not automatic replay.

Root inquiries attach to the latest committed event in their source/world scope,
including failed and interrupted work—not only successful answers. The history
cutoff is frozen at admission. Explicit `parent` and `memory_range` still
constrain it; a bounded prompt is not an unbounded transcript.

Known failures are outcomes. Interrupted execution can be uncertain.
Original-owner fencing allows late known completion while its generation remains
valid. Abort fences scheduling and records affected calls in history. It is
cooperative and does not undo effects; an external action already in flight may
still finish. Completed roots remain completed, and accepted descendants retain
their independent execution leases within the shared deadline and budget.

Model requests use complete JSON responses. Model outcomes are stored once;
conversation, memory and completed turns project those canonical records. The
`inquiry-v3` terminal result retains semantic text/message/status, coordinates
and aggregate usage. Zinc produces generic `start`/`display` presentation
envelopes from committed events before returning the result; consumers do not
interpret provider response shapes. Install matching PA protocol-2 binaries and
consumers. Complete assistant messages, tool calls/results and execution
receipts are persisted; transport fragments are not events. A database insert
constraint permits only explicit semantic and receipt kinds, never deltas or
arbitrary emissions. Event IDs count ledger records, not conversation messages.
Each complete model round emits while execution continues, including reasoning
visibility, refusals, truncation, filtering, tool calls and auxiliary outcomes.
Frames carry ID, author, occurrence time and source/ref/revision. Temporary
coordinates are execution-qualified, never fake durable IDs. Internal summary
completions remain cache bookkeeping.

`events` returns bounded committed pages. Reattachment emits saved events before
returning an outcome, without rerunning failed effects. Observers own delivery
receipts and cursors. Zinc has no Discord acknowledgment state or catch-up
queue.

Context and output ceilings are derived from the selected provider's advertised
capacities. `context-quota` is an optional operator cap, not a default 32K
restriction. `output: 0` uses available provider capacity rather than an
arbitrary fraction of the context window. Existing saved caps remain effective
when work is reauthorized. Explicit provider reasoning constraints are checked
before a completion request.

Token estimates use `ceil(bytes / 4)`; provider-reported usage remains separate.
Model requests consume the same work quota as queued tasks. Tool quota bounds
evaluation source/outcomes. Run aggregates can grow as accepted descendants
finish; individual receipts remain immutable.

## Memory

One canonical projection of the immutable ledger feeds two independent windows:

- Chronology follows ledger order. Aligned, equal-level blocks summarize exact
  ordered record membership, not global-ID intervals. Older blocks stay coarse;
  available budget refines recent blocks down to originals.
- Semantic retrieval searches original records beneath summaries. The original
  inquiry anchors lexical/spelling/Cygnet expansion and reranking. A bounded,
  checkpointed pool belongs to the call's frozen history. Only originals already
  present verbatim are deduplicated; compaction reselects evidence, never clears
  it.

Search defaults to a 50/50 memory-budget split. Disabling it gives chronology
the whole allowance. Both windows count rendered provenance headers.
`history-records` is a page/context-batch bound, not permission to omit older
admitted history. Required preparation either produces a complete cover or fails
explicitly.

Small blocks read up to 16 originals; larger blocks read two children. Bounded
source groups are compressed independently, then reduced in a balanced tree, not
repeatedly rewritten into a growing synopsis. Existing workers, checkpoints,
deadlines and shared quotas own all preparation. Cache identity uses ordered
children and compression policy, so later calls reuse completed blocks.

Every displayed memory item has ID, author and occurrence time. Summaries
identify their producer and creation time separately from the source period and
child IDs. Actual outcomes, failures and uncertainty remain distinct from
admissions. Summaries are lossy: expand originals before relying on an uncertain
action.

The trusted `invalidate` export takes `{"event":ID}` and excludes that summary
and its cached ancestors from subsequent reads. Originals remain immutable;
existing workers rebuild missing nodes on demand. Invalidation does not cancel
work or rewrite an already admitted model request; use explicit abort when
needed.

The balanced-cache approach draws on
[OptMem](https://github.com/VictorTaelin/OptMem), with scoped ledger membership
instead of a single dense note sequence.

Provider URL/token configuration supports llama/OpenRouter. An optional generic
`transport` library replaces HTTP transfer without exposing credentials to the
world. Its `request(url, method, body, headers)` function uses the same private
`(dyn :capability/config)` binding and returns
`{:status integer :body string :error :ok}` as one bounded response; there is no
chunk callback. Model selections are not additional grants. `thinking: default`
leaves provider controls unspecified. Reported usage is saved even when
subsequent response validation fails; missing usage remains unknown.

Semantic retrieval requires the pinned format-1 Cygnet index and stopwords. Set
`search: false` without those assets. Preserve stale development databases and
choose a fresh path; there is no compatibility migration.

Further contracts: [wiki](https://github.com/darkhorseprojects/zinc/wiki).
