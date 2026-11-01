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
asset-builder checksum and format; cached schema, integrity and provenance are verified. The builder verifies the source
once and publishes the immutable generated graph through a hard link rather than copying it into assets.
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
returns Janet definition forms for live bindings, image identity, checkpoint and
dirty status. Forms are serialized as Janet code, not reconstructed initializers;
they describe provenance, not current mutable values, and never replay.
Images without recorded source require explicit, audited annotation from history;
Zinc does not decompile native functions or invent definitions.
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
history. Revoked grants or changed import/setup declarations prevent saved execution.

Persist false keeps new call payloads in a bounded RAM journal over an immutable
archive prefix; nested children carry only the RAM additions, not copies of archived
history or images. Descendants stay temporary and cannot reattach. Controls/images may
reach disk and callers may retain results. This is not a temporary agent instance.
Accepted workers survive lost observers; interrupted code is never automatically
replayed. Supervisors must not kill their job/cgroup. `observe` reattaches without
rerunning code; `resume` explicitly reconciles resumable text work.

Root input `queue: false` atomically claims execution or records a terminal
`AgentBusy` outcome. It never commits queued work or retries automatically; explicit
resume must also claim immediately. Duplicate starts observe existing work without
receiving its execution lease. Connector uses this policy for synchronous peers.

## Language, grants and limits

Ordinary Janet bindings are available by default. Explicit selectors remain an
advanced restriction: core/* selects unqualified names, core/multiply selects *,
and namespaced selectors expand deterministically. Saved calls retain exact sets.
Native filesystem, network, subprocess, FFI, module loading, threads and environment
access remain sandboxed. The evaluator has its own module cache containing only zinc/design;
PA's foreign modules are reachable only through selected host bindings. Trusted setup may return parser/read/expander options.
Host operations live in a flat binding catalogue, not nested REPL schema metadata.
Schema `visible` settings and `public` resource fields are exposed through the
selected catalogue; host-side grant checks still enforce authority.

Named host grants remain: fs/list/read/write, http/request and process/run. Paths
reject traversal and links; HTTP permits configured bases/methods without redirects
or ambient proxies; processes use fixed argv/env and bounded output. These scopes
are not race-proof OS confinement: granted directory ancestry must not be concurrently
replaceable by an adversary. Keep databases, credentials, trusted modules and Git metadata
outside writable roots. PA imports carry JSON data, not native handles. Declare modules in
`repl.imports`, for example `discord: { module: "@connector/discord" }`; `export: self` selects one
callable under an alias. PA runtime import commands never enter world images. Saved provider configuration contains
credential references, never resolved tokens.

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
Compaction is demand-driven; completing an inquiry does not schedule speculative inference.
Memory covers remain stable across tool rounds until context pressure requires compaction.
Stable instructions and memory precede changing world state, and prompt JSON uses deterministic key ordering.
Usage remains separate from ceil(bytes/4) estimates, with reported replayed reasoning tokens accounted separately.

Provider names are arbitrary configuration keys. Providers select a protocol (chat-completions or responses),
URL, chat-path/rerank-path, optional catalogue paths by role, and an optional properties path with an escaped
{model} substitution. Models are an ID-keyed grant/profile map, not an array. Static profiles require role and
context; optional output, tools, parallel, images, control, efforts, reasoning-required and output-field describe
capabilities. Catalogue metadata and properties documents supply capabilities when discovery is configured;
explicit profiles override them, while context grants cannot exceed reported capacity. Failed discovery is an error.
Provider parameters carry non-structural wire settings; web-tools are enabled only with web-search permission.
No provider identities, endpoint URLs or model lists are built into inference code. A local server configuration is:

```yaml
providers:
  local:
    url: http://127.0.0.1:8080
    catalogue:
      chat: /v1/models
      rerank: /v1/models
    properties: /props?model={model}
    parameters: { cache_prompt: true }
chat: local:YOUR_MODEL
rerank: local:YOUR_RERANK_MODEL
```

Settle old work before replacing model arrays with maps and adding discovery paths to existing YAML. No database schema
change is required; saved calls still require their original grants to match current authority.

Credentials resolve only in trusted HTTP workers through token-env or an absolute credential-command returning a JSON
header object. Headers may also contain static protocol metadata. Command output/time are bounded and revocation is
checked while waiting. Resolved credentials are not saved in configuration or model admissions. Responses uses
store:false and locally selected context, preserving native output items and encrypted reasoning for same-model tool
continuation; switching models/protocols uses normalized messages instead. Cached/input/output/reasoning usage remains
available in the existing usage table. Optional cache-key is a stable routing hint, not a cache-hit guarantee.
Use a stable deployment key that also resolves for initialization and settlement, which have no Discord context.

An unfinished admitted inference is uncertain and is never automatically resubmitted, including during worker recovery.
Completed outcomes are reused. Endpoints configured with output-field: none cannot enforce output-token limits;
deadlines, byte limits and bounded-summary validation do not refund provider usage.

Views returns recorded memory windows with readable record headings, counts and a
retrieval-candidate table; render returns the exact model request,
without inference or recomputation. Submitted source remains inspectable history,
not executable persistence. Visible reasoning, SSE streaming and parallel tools
remain. Streaming previews store deltas separately from execution checkpoints;
observers fold only new deltas and skip unchanged previews. Binding source metadata is
read from native images on demand rather than copied into every event descriptor.
Presentation records identify agent/request/run/branch/caller; PA still uses its
existing wire protocol. Other entries include describe, instructions,
models, record, world, task, observe, resume, abort, invalidate and join.

Import `zinc/design` inside the evaluator and read design/document for architecture.
Use native `(doc math/rng-int)`, `(doc "string/")`, doc* and doc-of for language
help; describe is a value representation, not usage documentation.

**Package 0.2.0, database schema 1, inquiry-v1; PA wire stays 1.** Stop admissions and
settle/cancel old work before upgrading. Preserve the old database, Connector ledger
and source-world repository, then explicitly initialize fresh image-based state.
Do not overwrite old source snapshots or replay historical code for conversion.
Older schema-1 layouts are rejected; there is no migration or compatibility layer.
Verification uses compilation,
formatting, linting, type checking and artifact inspection; no tests are required.
