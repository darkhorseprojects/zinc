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

Main input selects one of text or code, not a named-operation dispatcher:

```json
{ "text": "Investigate the implementation", "request": "stable-operation-key" }
```

```json
{ "code": "(double 21)", "request": "another-operation-key" }
```

Inside world code:

```janet
(await (self {:text "Find the earlier decision about deployment"}))
(memory/expand event-id)
```

`memory/expand` is the only exposed memory function. It accepts an event ID and
returns scoped original records or summary children. Searching is an inquiry to
`self`; the semantic window retrieves relevant history internally. Internal
paged readers remain private to compaction.

Built-in functions are called directly. `self` admits descendant work and
returns a durable Zinc handle. `await` reads a descendant outcome. PA handles
remain separate, ephemeral observation handles.

`record`, `describe`, `document`, `models`, `events`, `pending`, `resume` and
`abort` are ordinary package exports used by invokers. `task` is the trusted
executor export, not a world binding. Generated environments receive neither PA
spawning nor private runtime configuration.

## Passive context

The trusted `record` export accepts
`{"records":[{"key":"external-id","author":"principal-id","at":"timestamp","text":"observed text"}]}`
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

Each complete call owns one detached executor, editable source file and Janet
REPL environment. Definitions and redefinitions survive its model/tool rounds;
mutations within that REPL are sequential. Parallel selves have separate files
and environments. Hard evaluation timeout terminates the call's evaluator rather
than reusing a possibly running heap.

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
requested filesystem/Git effects.

Optional `instructions` points to a plain world instruction file. Prompt
construction reads it without executing the world merely to discover
instructions.

## Capabilities

Capabilities are supplied Janet libraries exposing documented public proxy
functions:

```janet
(defn echo
  "(example/echo text) — Return text with the provided prefix."
  [text config]
  (string (config :prefix) text))
```

Provide a library and private configuration:

```json
{
  "capabilities": {
    "example": {
      "module": "/runtime/example.janet",
      "config": { "prefix": "hello: " }
    }
  }
}
```

Zinc discovers public callable bindings and their docstrings. It renders those
interfaces generically and installs proxies in the restricted world:

```janet
(import @example)
(example/echo "world")
```

Private configuration is appended only by the trusted runtime, never exposed as
a world argument. Private definitions and macros are not provided. Public proxy
functions must be documented. Every execution checks the currently provided
interface; changing a world binding cannot manufacture authority.

There are no process-program descriptors, function-name selectors or recursive
import-delegation catalogs. Proxy libraries may cross executable boundaries;
Zinc does not know their provider.

## User and agent profiles

`inference` controls agent/model-request execution. `permissions` lists built-in
memory/model/work functions. `capabilities` supplies external libraries. These
are distinct.

An authorized human execution may have `inference: false`, `save: true`, and a
trusted `agent` profile. Text selves use that agent profile; code selves retain
the caller's profile. Profiles must share source/store/world/file identity.
Saved work is reauthorized against current profiles.

`save` is an optional built-in, limited to the configured world source file:

```janet
(save "Update world")
(save "Try another approach" {:branch "experiment"})
(save "Integrate" {:merge "refs/heads/self/BRANCH"})
(save "Keep an earlier call" {:call CALL-ID})
(save "Publish" {:push true})
```

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

SQLite format 1 stores admissions, immutable events/outcomes, attempts,
task-owned leases, checkpoints, images and usage. Accepted task execution can
finish and commit after its PA observer dies. It cannot survive death of its own
executing process or OS scope.

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
valid. Abort fences scheduling and records the affected tasks in branch history.
It is cooperative and does not undo effects; an external action already in
flight may still finish. Completed roots remain completed.

Model requests use complete JSON responses. Complete assistant messages, tool
calls/results and execution receipts are persisted; transport fragments are not
events. A database insert constraint permits only explicit semantic and receipt
kinds, never deltas or arbitrary emissions. Event IDs count ledger records, not
conversation messages. Each complete model round emits while execution
continues, including reasoning visibility, refusals, truncation, filtering, tool
calls and auxiliary outcomes. Frames identify the execution and its
source/ref/revision; temporary frames have null durable event coordinates.

`events` returns bounded committed pages. Reattachment emits saved events before
returning an outcome, without rerunning failed effects. Observers own delivery
receipts and cursors. Zinc has no Discord acknowledgment state or catch-up
queue.

Token estimates use `ceil(bytes / 4)`; provider-reported usage remains separate.
Tool quota accounts full stored code/outcomes. Context and summary quotas bound
chronology, retrieval and compaction. History and retrieved text are data, not
instructions.

Provider URL/token configuration supports llama/OpenRouter. An optional generic
`transport` library replaces HTTP transfer without exposing credentials to the
world. Its `request(url, method, body, headers, config)` function returns
`{:status integer :body string :error :ok}` as one bounded response; there is no
chunk callback. Model selections are not additional grants. `thinking: default`
leaves provider controls unspecified. Reported usage is saved even when
subsequent response validation fails; missing usage remains unknown.

Semantic retrieval requires the pinned format-1 Cygnet index and stopwords. Set
`search: false` without those assets. Preserve stale development databases and
choose a fresh path; there is no compatibility migration.

Further contracts: [wiki](https://github.com/darkhorseprojects/zinc/wiki).
