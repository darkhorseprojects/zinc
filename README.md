# Zinc

Zinc runs Janet tasks and restartable workflows with SQLite history and shared JSON values.

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

## Invocation

src/main.janet accepts one Portable Agents version-1 call on stdin. PA_FRAME_BYTES bounds frames.
Parameters contain input, config, imports, an optional after cursor and the expected store identity
when attaching. Connector capability imports require its live request-scoped broker.

self admits :text, :code or :stages work, emits an admission, executes or recovers it, streams committed
presentation and returns an outcome. Reattachment uses the same request identity and cursor.
Observation loss does not cancel execution. Admission does not mean completion.

Other entries are describe, instructions, models, init, status, abort, record, world, views, render,
diagnostics, invalidate and resolve. Abort cancels a request tree without undoing external effects.

## Durable stages

A workflow is an immutable ordered array of stages. Each has a unique lowercase id and optional after
names referring to earlier stages. Unrelated stages can run concurrently. Failed dependencies prevent
dependent execution; unrelated work continues.

```janet
(self {:stages [{:id "extract" :code "{:answer 42}"}
                {:id "publish" :after ["extract"] :call "world/commit"
                 :arguments "[((input) :extract)]"}]})
```

A code stage evaluates pure Janet and saves its JSON result. A call stage evaluates arguments as pure
Janet, admits one granted host operation, then saves its outcome. Both expressions receive declared
dependency results through `(input)`, using keyword keys matching stage IDs. Use :null for explicit
JSON null; nil-valued object fields are omitted. Definitions belong in source, not stored worlds.

Recovery reuses completed stages and recorded operation outcomes. Interrupted computation and argument
construction may repeat before a result or admission commits. Dispatch commits before external invocation.
A dispatch without an outcome remains uncertain and is not blindly repeated. Discord creation receipts
can reconcile automatically; otherwise inspect external state and supply an outcome with verification
evidence through task/resolve or the direct-execution resolve entry. Evidence is the caller's attestation,
not an independent verifier. Model calls use the same admission/dispatch/outcome distinction.

Ordinary code scripts execute once with journaled host calls. A started script interrupted before its
result commits fails with ScriptInterrupted on recovery. Zinc does not serialize stacks, closures,
fibers, channels or native objects, and does not reconstruct remaining source. Use stages when progress
must survive a crash. self returns an independent child's handle; task/wait can wait for descendants of
its caller or declared dependencies from a call stage. Parent completion does not cancel descendants.

Stored state contains JSON rather than runtime images. Ordinary source changes do not invalidate it by
file hash. Recovery still checks current grants, task ownership, deadlines and world epochs. Changes to
public capability contracts require deliberate handling. Historical binary-image stores are unsupported for execution;
retain their original installation if unfinished work must be recovered. Zinc does not migrate them.

## Worlds and history

world/get reads shared JSON values by string key. world/commit explicitly publishes values, optionally
with an expected revision. It does not save execution. Worlds do not isolate memory history.

`/world view [point]` inspects a publication. `/world rewind <id|hash>` restores one under direct-execution
authority, increments its epoch and fences unfinished old work. Rewind does not undo effects or erase history.
Branches are initialized once from configuration; changing from does not reset an existing branch.

The core tables are events, images, claims and worlds. Images hold deduplicated JSON values and configuration
snapshots; claims hold leases, waits and one-shot script admission state. Terminal claims are removed.
FTS is a derived memory index. views, render and memory/expand expose retained prompts, summaries and records.

## Temporary execution and limits

persist:false selects a bounded RAM database with inherited history and world values. Descendants inherit
that persistence. Temporary work cannot create durable descendants or reattach after owner loss. Connector
also keeps its temporary request, diagnostic and delivery state in RAM. External services and explicit
external effects remain outside this storage guarantee.

Resource and byte limits are enforced, but Zinc is not an OS memory sandbox. Scripts run in an isolated
Janet thread with a restricted binding environment and native resource restrictions. Custom setup and
host modules are trusted configuration. Filesystem grants reject traversal and observed links, but are
not race-safe confinement for directories another process can mutate. Do not grant such directories to
untrusted work. HTTP verifies certificates and hostnames, follows no redirects, and uses bounded requests.
The pinned URL parser supports DNS names and IPv4, not IPv6 literals.
