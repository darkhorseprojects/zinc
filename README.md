# Zinc

Zinc runs independent Janet scripts and effects with SQLite history, asynchronous model continuation
and native image-based worlds.

## Installation

Install under `~/.agents/zinc` or `%LOCALAPPDATA%\agents\zinc`. Each installation owns its source,
dependencies, assets and private database. Install Connector separately.

Use Janet 1.42+, Jpm, a C compiler, OpenSSL headers and trusted CA certificates, Python 3.11+ and Git.
Build dependencies with `JANET_SYSTEM_SQLITE=0 jpm --local --cflags=-std=c99,-DSQLITE_ENABLE_FTS5,-DSQLITE_USE_URI=1 deps`,
then run `jpm --local run tls` to rebuild the pinned TLS dependency with its cancellation cleanup fix,
and build retrieval assets with `jpm --local run assets`. MSVC flags are
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
retain JSON-compatible values on the process boundary; native return values use explicit Janet-type
descriptors. Host arguments/results remain JSON data. self/wait explicitly waits for a descendant's root
outcome, not its VM drain or world publication.

Grant core/*, array/*, ev/*, self/* and effect/* as appropriate in execution profiles. Use `(doc)` to
list available bindings and `(doc name)` to inspect one. Core grants include arithmetic `/` and `/=`.
Each evaluator seeds its default PRNG from OS entropy; explicit math/rng values can persist in worlds.
There are no task/* compatibility aliases.

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
Reasoning and execution events are presented immediately. Final answer text is presented once, from the
committed inquiry outcome; the inquiry remains receptive while descendants are unfinished.
A timer reconciles cross-process writes and leases. Observation is read-only and cannot execute work.

Discord receives exact source in clojure blocks, fenced output, effect receipts and root results.
Messages are independent; footers identify their script, call and event. Complete effect values remain
in execution history and model context.

Other entries are describe, instructions, models, init, status, abort, record, world, views, render,
diagnostics, invalidate and resolve. Abort cancels an execution tree without undoing external effects.

## Restart and uncertainty

Admission commits before dispatch. Completed effect results survive independently of their originating VM.
Restart executes undispatched effects and reports dispatched effects without an outcome as uncertain.
The model receives the original effect identity, attempt, arguments and operation identity automatically.
It investigates current external state, then effect/resolve or the direct resolve entry records a verified
value/error, or an explicitly approved retry, with evidence. Retries retain the logical effect identity.
A stale decision cannot resolve a newer attempt. Evidence is an attestation, not an independent verifier.
Caught filesystem read and pre-dispatch validation failures settle as failed. Failures after a potentially
mutating dispatch remain uncertain unless the operation reports a definitive outcome.

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

Scripts restore the selected world's native user environment. Successful scripts automatically publish
changed environments after their fibers settle. Definitions, macros, private bindings, variables, mutations,
closures and their reachable state persist without rerunning initializers. Native marshaling preserves
shared references and cycles. Output and discarded expression results are not world bindings. An unchanged
environment creates no publication. world/remove takes a symbol and removes a local binding.

Freshly granted host bindings, output ports and invocation accessors are rebound on restoration; the image
does not restore old capability connections. Unsupported reachable values fail publication explicitly,
without silently discarding state. An early root return does not promise successful world publication:
settlement failures remain visible even after that return. Native event-loop waits are not restartable.

Each script publishes against the revision it loaded. Conflicting images are retained as inspectable
world-image artifacts, without replacing the head, merging graphs or replaying effects. Worlds do not
isolate memory history.

`/world view [point]` inspects a publication. `/world rewind <id|hash>` restores one under direct-execution
authority, increments its epoch and fences unfinished old work. Rewind does not undo effects or erase history.
Branches are initialized once from configuration; changing from does not reset an existing branch.

World inspection shows complete recorded defining forms in clojure blocks, not signatures or JSON.
These forms are source provenance, not a reconstruction of the current mutable heap and never a replay
program. The native image holds the actual state. The same defining source is included in model context.

Images hold deduplicated JSON configuration/model input and native world bytes with matching Janet runtime
metadata. Claims hold leases, waits and source progress. Terminal claims are removed. FTS is a derived
index. Successful VM-drain results do not duplicate root returns; unsuccessful settlement remains visible
in presentation and memory. views, render and memory/expand expose retained originals. Rerank inference
identities include the exact query and ordered document excerpts; cached indices never refer to a different input.

Existing JSON-world installations need an explicit offline image conversion before upgrading. Preserve
the database and store identity; do not reset history or automatically replay historical scripts. No
schema or version change is required.

## Temporary execution and limits

persist:false selects a bounded RAM database with inherited history and world images. Descendants inherit
that persistence. Temporary work cannot create durable descendants or reattach after owner loss. Connector
also keeps its temporary request, diagnostic and delivery state in RAM. External services and explicit
external effects remain outside this storage guarantee.

Resource and byte limits are enforced, but Zinc is not an OS memory sandbox. CPU-bound Janet code can
occupy its own cooperative VM; it does not execute on the coordinator thread. Custom setup and host
modules are trusted configuration. Filesystem grants reject traversal and observed links, but are not
race-safe confinement for directories another process can mutate. Do not grant such directories to
untrusted work. HTTP verifies certificates and hostnames, follows no redirects, and uses bounded requests.
The pinned URL parser supports DNS names and IPv4, not IPv6 literals.
