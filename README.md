# Zinc

Zinc runs independent Janet tasks with SQLite memory, shared worlds and durable VM continuations.

## Installation

Install under `~/.agents/zinc` or `%LOCALAPPDATA%\agents\zinc`. Each installation owns its source, dependencies,
assets and private database. Connector is installed separately. Git tracks installed source, not running state.

Use Janet 1.42+, Jpm, a C compiler, OpenSSL headers and trusted CA certificates, Python 3.11+ and Git. Build dependencies
with `JANET_SYSTEM_SQLITE=0 jpm --local --cflags=-std=c99,-DSQLITE_ENABLE_FTS5,-DSQLITE_USE_URI=1 deps`, then retrieval
assets with `jpm --local run assets`. MSVC flags are `/nologo,/MD,/DSQLITE_ENABLE_FTS5,/DSQLITE_USE_URI=1`;
Jsec uses VCPKG_ROOT on Windows and OPENSSL_PREFIX for nonstandard macOS installations.

Set JANET_PATH to the installation's jpm_tree/lib. SQLite must support FTS5, URI filenames and memdb. Native modules
must match Janet's ABI. Initialize fresh state with `agc init`. No agent executable or shared runtime directory is needed.

## Invocation

src/main.janet accepts one version-1 call on stdin. Parameters contain input, config, imports, an optional after cursor and the expected store identity when attaching.
PA_FRAME_BYTES bounds transport frames. Portable Agents defines only the wire envelopes; Zinc owns these methods.

self admits full input or attaches to an existing request identity. It emits an admission event, executes or recovers
work, streams committed presentation and returns an outcome. Disconnecting observation does not cancel execution.
Repeated admission uses the same request identity. There is no separate run entry.

Observation within self uses a read-only connection. status reads an outcome; abort cancels a request tree without undoing effects. Other entries are
describe, instructions, models, init, record, world, views, render, diagnostics, invalidate and resolve.

## Execution and recovery

Ordinary host calls need no operation keys. self returns an independent child's handle; task/wait explicitly suspends
until its outcome exists. Parent completion neither joins nor cancels independent children.

At VM safepoints, Zinc saves the complete reachable task graph: stacks, program counters, locals, closures, output and
managed async waits. A restart resumes that graph, not the script's source. Managed ev/go, ev/spawn, ev/gather,
ev/go-gather, ev/sleep, ev/chan, ev/take, ev/give, ev/count, ev/chan-close and ev/cancel use serializable scheduling state.
Other native ev operations are not exposed. Random-generator state is task-local; host observations are journaled.

Sockets, processes, SQLite connections and thread channels remain outside images. Pure computation since the last
safepoint may repeat. Unsupported native objects and C stack frames fail snapshotting before new effects dispatch.
Setup may supply an expander, not a live parser or reader. Images require their original runtime and registry.

An operation admission and its waiting continuation commit together. Dispatch is recorded before external invocation;
definitive outcomes are stored before resumption. A recorded outcome is reused. Dispatch without an outcome is uncertain,
not failed. Connector delivery receipts are checked automatically when available. Otherwise inspect external state before
task/resolve records a verified value/error and evidence. The direct-execution resolve entry also accepts normalized
model outcomes. Transport errors, lease expiry and missing messages do not establish that an effect never happened.

Current grants are checked again on recovery. Claims fence publication and bound active tasks. Late operation receipts
may be retained, but stale workers cannot advance continuations or worlds. Deadlines and configured resource quotas
remain enforced; this is not an OS memory sandbox. HTTP uses bounded Spork/Jsec requests with certificate and hostname
verification and no redirects. The pinned parser accepts DNS names and IPv4, not IPv6 literals.

## Worlds

world/get reads shared values. world/commit explicitly publishes values or serializable definitions; it is not an execution
save. Independent tasks exchange snapshots, not live heap pointers. Worlds and task continuations use database-backed
binary images. There is no world/save or world/fork.

`/world view [point]` inspects a publication; `/world rewind <id|hash>` restores one under direct-execution authority.
Rewind increments the world epoch and fences unfinished old work. It does not erase history, resurrect old tasks or undo
external effects. Branches are initialized once from configuration only:

```yaml
world: main
worlds:
  main: {}
  experiment: { from: "publication-id-or-image-hash" }
```

self may select only granted worlds. Changing a branch's from field does not reset it.

## Storage and temporary work

The core tables are events, images, claims and worlds. Events retain admissions, dispatches, outcomes and world
publications. Claims retain the latest task image, scheduling state and lease. Superseded unreferenced task images are
reclaimed. Worlds retain publication heads and rewind epochs. FTS is a derived memory index. No schema/version number
is increased; incompatible layouts are rejected structurally. Existing JSON checkpoints cannot become VM stacks.

persist:false uses the same execution machinery in a bounded RAM database, with inherited history and world images.
It cannot create durable descendants. Observer failure does not cancel it, but losing the owning process loses its
session. Temporary work is never silently recreated.

Chronological memory, bounded summaries, retrieval, original records, image budgeting and exact provider requests remain
inspectable through views, render and memory/expand. Markdown is instruction/data, not executable persistence.
