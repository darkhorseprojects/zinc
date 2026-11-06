# Zinc

Zinc runs independent Janet scripts and effects with SQLite history, asynchronous model continuation
and shared JSON values.

## Installation

Install under `~/.agents/zinc` or `%LOCALAPPDATA%\agents\zinc`. Each installation owns its source,
dependencies, assets and private database. Install Connector separately.

Use Janet 1.42+, Jpm, a C compiler, OpenSSL headers and trusted CA certificates, Python 3.11+ and Git.
Build dependencies with `JANET_SYSTEM_SQLITE=0 jpm --local --cflags=-std=c99,-DSQLITE_ENABLE_FTS5,-DSQLITE_USE_URI=1 deps`,
then retrieval assets with `jpm --local run assets`. MSVC flags are
`/nologo,/MD,/DSQLITE_ENABLE_FTS5,/DSQLITE_USE_URI=1`. Jsec uses VCPKG_ROOT on Windows and OPENSSL_PREFIX
for nonstandard macOS installations. Set JANET_PATH to the installation's jpm_tree/lib.

SQLite must support FTS5, URI filenames and memdb. Native modules must match Janet's ABI.
Initialize a fresh installation with `agc init DIRECTORY`.

`examples/models.ini` is an optional external model-server preset. Provision its server and weights
separately. Zinc does not read this file or verify those model downloads.

## Execution

src/main.janet accepts one Portable Agents version-1 call on stdin. PA_FRAME_BYTES bounds frames.
Parameters contain input, config, imports, an optional after cursor and the expected store identity
when attaching. Connector capability imports require its live request-scoped broker.

self admits :text or :code, emits an admission, executes or recovers admitted work, streams committed
presentation and returns a terminal outcome. A root outcome event can arrive before the invocation ends:
root completion does not wait for native fibers, effects or descendants. Reattachment uses the same
request identity and cursor. Observation loss does not cancel execution. Admission is not completion.

The model's self tool accepts full Janet source only. Calls in the same response are admitted together
and execute independently. There is no workflow JSON, stage language or implicit sibling gather.

```clojure
(def ctx (discord/context))
(ev/go (fn [] (discord/add-reaction (ctx :message) "👋") nil))
(ev/go (fn [] (discord/add-reaction (ctx :message) "✨") nil))
(print "Reactions started")
nil
```

Native Janet schedules ev fibers, channels, timers and threads. Each script has an isolated evaluator
thread; blocking host implementations execute in independent worker threads, not the coordinator loop.
A generic bridge journals each granted host call as an independent effect. Waiting suspends only the
calling fiber. Each effect commits its own result and wakes inference and observation immediately.
Configured parallel limits apply separately to script VMs, effects and inquiry execution.

The root return, VM lifetime and external effects have distinct completion boundaries. Output ports
schedule publication without blocking Janet's non-yieldable output callback. Output is not accumulated
into the final result. Successful native fiber return values are displayed as Janet text. Root returns
and host arguments/results are JSON data; return nil after launching fibers rather than returning a
native fiber/channel object. self/wait explicitly waits for a descendant's root outcome, not its VM drain.

Grant native ev/*, self/* and effect/* as appropriate in execution profiles. These replace the former
public task/* bindings; there are no compatibility aliases.

## Ownership and data flow

```text
model response -> engine/infer -> atomic script admissions and provider receipts
                                      |
                                  engine/run
                                      |
                                runtime/run VM
                                      |
                       generic host-call admission
                                      |
                    independently claimed engine/invoke
                                      |
                          committed effect outcome
                         /            |            \
                 resume caller   wake inference   observe -> Connector -> Discord
```

engine/run owns scheduling and lease renewal. runtime/run owns native VM lifetime and result delivery,
not effect execution. store owns admission, claims, outcomes and post-commit notification. engine/infer
uses the same committed-change query for eligibility and context. model/call journals inference;
provider encodes and decodes Responses or Chat Completions and preserves native reasoning for replay.
A model answer is presented immediately; its inquiry remains receptive while descendants are unfinished.
A timer reconciles cross-process writes and leases. Observation is read-only and cannot execute work.

Discord receives exact source in clojure blocks, fenced output and individual effect/root results replying
to the source. Model reasoning and footer metadata retain their existing presentation.

Other entries are describe, instructions, models, init, status, abort, record, world, views, render,
diagnostics, invalidate and resolve. Abort cancels an execution tree without undoing external effects.

## Restart and uncertainty

Admission commits before dispatch. Completed effect results survive independently of their originating VM.
Restart executes undispatched effects and reports dispatched effects without an outcome as uncertain.
The model receives the original effect identity, attempt, arguments and operation identity automatically.
It investigates current external state, then effect/resolve or the direct resolve entry records a verified
value/error, or an explicitly approved retry, with evidence. Retries retain the logical effect identity.
A stale decision cannot resolve a newer attempt. Evidence is an attestation, not an independent verifier.

Janet's native event loop is not serialized. Interrupted VMs are marked uncertain with their completed
source-form count; their source, output and committed effects remain available. Restart never replays
original source. The model reconstructs only remaining work in a new script, without inventing lost locals
or native waits. Direct execution can use its configured agent profile for an automatic recovery inquiry;
without inference authority, uncertainty remains available for inspection rather than expanding authority.
Interrupted chat turns are continued from committed evidence; uncommitted provider tool calls are never
admitted. Definitive provider failures retain their diagnostics rather than being automatically retried.

There is no exactly-once promise for arbitrary external systems. If inspection cannot establish a safe
outcome or retry, uncertainty remains explicit. No operation-specific reconciliation is hidden in the engine.

The existing events, images, claims and worlds tables remain unchanged. Their historical task/operation
storage names are internal; no schema migration or version bump is required. Historical JSON workflow
records remain inspectable, but unfinished old workflows must finish under their original installation
before upgrading. New execution does not support workflows or pretend they were Janet source.

## Worlds and history

world/get reads shared JSON values by string key. world/commit explicitly publishes values, optionally
with an expected revision. It does not save execution. Worlds do not isolate memory history.

`/world view [point]` inspects a publication. `/world rewind <id|hash>` restores one under direct-execution
authority, increments its epoch and fences unfinished old work. Rewind does not undo effects or erase history.
Branches are initialized once from configuration; changing from does not reset an existing branch.

Images hold deduplicated JSON configuration, model input and world values. Claims hold leases, waits and
source progress. Terminal claims are removed. FTS is a derived index. Root returns are not duplicated by
VM-drain results in presentation or memory. views, render and memory/expand expose retained originals.

## Temporary execution and limits

persist:false selects a bounded RAM database with inherited history and world values. Descendants inherit
that persistence. Temporary work cannot create durable descendants or reattach after owner loss. Connector
also keeps its temporary request, diagnostic and delivery state in RAM. External services and explicit
external effects remain outside this storage guarantee.

Resource and byte limits are enforced, but Zinc is not an OS memory sandbox. CPU-bound Janet code can
occupy its own cooperative VM; it does not execute on the coordinator thread. Custom setup and host
modules are trusted configuration. Filesystem grants reject traversal and observed links, but are not
race-safe confinement for directories another process can mutate. Do not grant such directories to
untrusted work. HTTP verifies certificates and hostnames, follows no redirects, and uses bounded requests.
The pinned URL parser supports DNS names and IPv4, not IPv6 literals.
