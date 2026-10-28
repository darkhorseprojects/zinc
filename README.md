# Zinc

Zinc owns Janet worlds, execution, Git checkpoints, private history and bounded
memory retrieval. Portable Agents supplies the process/byte boundary; Connector
supplies Discord identity, routing and delivery. Neither owns Zinc state.

## Installation

Extract Zinc 0.2.0 to an immutable `~/.agents/shared/zinc/BUILD_ID/` directory.
Keep `agent` and `agc` on PATH. Each independent agent gets its own directory,
ac.yaml, history database, world repository, Connector ledger and bot credential.
Do not share mutable stores between bots. See Connector's example configuration.

Packages include `zinc.md`, `design.md`, `src/`, `lib/`, verified
`assets/stopwords.json`, generated `assets/cygnet.db`, attribution and model locks.
Resolve BUILD_ID during provisioning; never retarget an active instance's package.
Configure Git author identity, then use `agc init INSTANCE` for a fresh world.
`agc create INSTANCE --from EXISTING_INSTANCE` copies configuration, not state or
credentials. The application also exports a byte-valued `init` entry.

Native releases target Ubuntu 24.04/glibc, macOS 15 and Windows 11, on x86-64 and
ARM64. Native modules must match Janet's ABI. Linux needs libcurl and CA
certificates; macOS needs curl. Windows needs the matching Visual C++ runtime,
PA's janet.dll and Zinc's bundled curl DLLs beside agent.exe; retain their licenses.
These are not musl or self-contained builds.

Build with Janet 1.42+, Jpm, Python 3.11+, Git, tar, a C compiler and libcurl
headers. POSIX needs pkg-config; MSVC needs CURL_ROOT:

```sh
JANET_SYSTEM_SQLITE=0 jpm --local --cflags=-std=c99,-DSQLITE_ENABLE_FTS5 deps
jpm --local run package
```

MSVC flags are `/nologo,/MD,/DSQLITE_ENABLE_FTS5`; PYTHON selects the interpreter.
The assets task verifies pinned inputs, downloads Cygnet, builds a format-1 graph,
and preserves resource citations/licences. Cache identity includes source checksum,
indexer checksum and format; cached schema, integrity and provenance are verified.
Models remain separately provisioned; models.lock records their provenance.

## Worlds and calls

The authoritative current-world descriptor is in SQLite. Git stores pinned native
binding images and saved commits; world/world.jimage is a checkpoint artifact.
Successful definitions, vars, closures, mutations, aliases and cycles persist.
Initializers and prints do not replay. Unsupported values fail snapshotting.
A per-evaluation registry resolves the fresh authorized base and host callables;
credentials, channels, invocation configuration and output buffers are not images.
Format/runtime identity is checked before unmarshaling.

Failures discard only the current candidate, never earlier successful work.
Cancellation does not undo publications or external effects. Direct code and tool
code publish identically. One durable root owns an instance world, even while
waiting. Queued roots refresh from the instance head on first execution. Parallel
children fork the same snapshot and never merge. Explicit revisions remain pinned
and do not replace the instance head.

```janet
(var counter 0)
(set counter (+ counter 1))
(world/save "Keep the counter")
(world/view)
(world/remove 'counter)
```

The external world entry uses the same operations: view, save with message, discard,
switch with commit, and remove with name. View accepts a historical event point and
returns bounded bindings, image identity, checkpoint and dirty status, not source.
Discard/switch end the current evaluation. Save/switch/discard require the durable
instance root; switch requires saved/discarded changes. Saving after a rewind forks
Git history. Save intent is durable before Git ref mutation; recovery reconciles
only that intent, never arbitrary code or external effects. Use ordinary Git for
pushing and explicit merges, not automatic binary-image merging.

Self takes exactly one of text/code. Code returns evaluation text; text returns a
map with text. Text uses the configured agent profile; profiles share store/world
identity. Self snapshots live bindings before forking. Native `ev/gather` and model
multi-tool calls retain concurrent execution. Join local fibers that matter.
Parent and memory_range bound history, not world state. Parent 0 defaults to empty
history. Revoked grants or changed module/setup paths prevent saved execution.

Persist false keeps call payloads in a bounded RAM journal within the existing
instance; descendants stay temporary and cannot reattach. Controls/images may
reach disk and callers may retain results. This is not a temporary agent instance.
Accepted workers survive lost observers; interrupted code is never automatically
replayed. Supervisors must not kill their job/cgroup. `observe` reattaches without
rerunning code; `resume` explicitly reconciles resumable text work.

## Language, grants and limits

Ordinary Janet bindings are available by default. Explicit selectors remain an
advanced restriction: core/* selects unqualified names, core/multiply selects *,
and namespaced selectors expand deterministically. Saved calls retain exact sets.
Native filesystem, network, subprocess, FFI, module loading, threads and environment
access remain sandboxed. Trusted setup may return parser/read/expander options.

Named host grants remain: fs/list/read/write, http/request and process/run. Paths
reject traversal and links; HTTP permits configured bases/methods without redirects
or ambient proxies; processes use fixed argv/env and bounded output. These scopes
are not race-proof OS confinement. Keep databases, credentials, trusted modules and
Git metadata outside writable roots. Host RPC carries JSON data, not native handles.
Modules may select one exported callable under an alias with `export: self`.

`world-bytes` defaults to 16 MiB and limits serialized images, not heap usage.
`source-bytes` defaults to 1 MiB and limits submitted code. Zero means unlimited for
run-seconds (default 0), seconds (120), http-ms (600000), and output (0). Finite
authorized ceilings still constrain unlimited requests. Leases remain finite.
Finite evaluation deadlines interrupt inside the evaluator VM; not every blocking
native operation is interruptible. The default PRNG is entropy-seeded per invocation;
persist a math/rng object for deterministic continuing state.

## Memory and documentation

Chronology uses checked, invalidatable summaries. Retrieval uses stopwords, exact
Cygnet expansion, history trigrams, FTS candidates and model reranking, not vectors
or web search. Disabling memory-retrieval gives chronology the whole memory budget.
Score is the reranker cutoff; memory/expand pages originals and summary children.
Usage remains separate from ceil(bytes/4) estimates. Provider grants select URLs,
model IDs and token-env references; credentials resolve only in trusted code.

Views returns recorded memory windows; render returns the exact model request,
without inference or recomputation. Submitted source remains inspectable history,
not executable persistence. Visible reasoning, SSE streaming and parallel tools
remain. Presentation records identify agent/request/run/branch/caller; PA still
uses its existing wire protocol. Other entries include describe, instructions,
models, record, world, task, observe, resume, abort, invalidate and join.

Import `zinc/design` inside the evaluator and read design/document for architecture.
Use native `(doc math/rng-int)`, `(doc "string/")`, doc* and doc-of for language
help; describe is a value representation, not usage documentation.

**Package 0.2.0, database schema 1, inquiry-v1; PA wire stays 1.** Stop admissions and
settle/cancel old work before upgrading. Preserve the old database, Connector ledger
and source-world repository, then explicitly initialize fresh image-based state.
Do not overwrite old source snapshots or replay historical code for conversion.
There is no migration or compatibility layer. Verification uses compilation,
formatting, linting, type checking and artifact inspection; no tests are required.
