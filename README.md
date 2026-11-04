# Zinc

Zinc runs independent Janet tasks. Each task commits its own progress to SQLite; inference and presentation observe
those commits without gathering sibling results.

## Source installation

Install source under `~/.agents/zinc` on Linux/macOS, or `%LOCALAPPDATA%\agents\zinc` on Windows. Connector is a
separately installed application, not a directory beneath that root. No shared source, library or asset folder is
required.

Use Janet 1.42+, Jpm, a C compiler, OpenSSL development headers and trusted CA certificates, Python 3.11+ and Git.
Build this installation's dependencies with
`JANET_SYSTEM_SQLITE=0 jpm --local --cflags=-std=c99,-DSQLITE_ENABLE_FTS5,-DSQLITE_USE_URI=1 deps`, then build retrieval
assets with `jpm --local run assets`. MSVC flags are `/nologo,/MD,/DSQLITE_ENABLE_FTS5,/DSQLITE_USE_URI=1`;
Jsec uses VCPKG_ROOT on Windows and OPENSSL_PREFIX for a nonstandard macOS OpenSSL installation.

Set JANET_PATH to this installation's jpm_tree/lib. SQLite must support FTS5, URI filenames and the memdb VFS. Native
modules must match Janet's ABI. There is no Zinc or agent executable to build.

A second agent may be a modified Git worktree of this repository. Each worktree owns its configuration, dependencies,
generated assets and private database. Connector's create operation creates such a worktree and configuration. Provision
its own dependencies/assets, then initialize fresh state with agc init.

## Invocation

Connector invokes src/main.janet with Janet. One version-1 call arrives on stdin, with method and params. Parameters
contain input, effective config, and Connector-owned capability commands. PA_FRAME_BYTES supplies the bounded transport
limit. The source entry replies with ready, events and one terminal result/error. No manifest is needed.

self admits work and returns a committed receipt. run executes that request's task tree independently of observation.
observe uses a read-only connection and cursor. status reads an outcome; abort explicitly cancels a request tree without
undoing prior commits or external effects.

Other entries are describe, instructions, models, init, record, world, views, render, diagnostics, invalidate and
resolve. World inspection reads committed JSON values. World edits are authorized task/commit scripts, not Git-image
save/discard operations.

## Scripts

Read task/checkpoint at entry and guard finished stages. task/commit accepts checkpoint, put, remove, expect and text;
progress and published values become durable in one transaction. world/get and world/view read shared committed values.
Locals, closures, channels and fibers are process-local, not durable continuations.

self returns a handle immediately. task/status inspects it. task/wait is an explicit dependency: checkpoint first,
because waiting releases execution capacity and the caller re-enters from source. Native ev/spawn and ev/gather remain
available within scripts. Parent completion does not join independent descendants.

Effects such as fs/write, http/request, process/run, imported capabilities and self require a final map containing only
operation, whose value is a stable string key. Reusing a key with different arguments fails. Completed outcomes are
reused; attempted effects without outcomes block for reconciliation instead of being blindly repeated. The
direct-execution profile may use resolve to record a verified outcome: value for an operation success or an error
diagnostic for failure. Model reconciliation requires a verified normalized response; the runtime assigns outcome state
and model coordinates. Explicit provider and capability failures are recorded and retain their original diagnostics;
unknown outcomes retain the operation ID and block replay. Empty or incomplete model answers and entirely rejected
tool admissions stop the task rather than silently issuing another inference.

HTTP uses Spork with Jsec TLS, certificate and hostname verification, bounded streaming reads, and no redirects.
The pinned URL parser supports DNS names and IPv4; unsupported URLs, including IPv6 literals, are rejected before dispatch.

parallel bounds active durable tasks through shared claims. Deadlines and current ownership are checked before
publication. Task depth, work, tool output, source, response, context, image and RAM-journal limits bound their
respective resources; this is not an OS memory sandbox.

## Temporary execution

persist:false retains new execution records and shared-value changes in a bounded RAM database. Existing history is
copied at admission. A temporary session cannot create durable descendants. A durable caller may retain returned values
and its own admission metadata. Observer failure does not cancel its executor, but losing the owning process can lose
the entire session. No restart durability is promised.

## Memory and inspection

Chronological memory, bounded paged summaries, semantic retrieval, original-record expansion, image budgeting, exact
provider requests and raw usage remain recorded. views reports memory composition and summary sources; render includes
readable and exact requests. Markdown is ordinary instruction/documentation text, never executable persistence.

## Storage compatibility

The execution core is two tables: events and claims. The memory FTS index is derived. Version numbers and PRAGMA
user_version are not increased by this change. The old call_controls/image-based layout is rejected structurally;
initialize a fresh database rather than opening it with incompatible source. No migration or backward-compatibility
layer is provided.

See [design.md](design.md) for ownership and recovery rules and [zinc.md](zinc.md) for agent instructions.
