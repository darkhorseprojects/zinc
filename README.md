# Zinc

Zinc 0.2.0 is a Janet source package for Portable Agents. It owns call-local
worlds, execution profiles, private history and bounded retrieval. Connector is
optional; Zinc has no resident service or socket.

## Install

Use Janet 1.42+, Jpm, Git and libcurl development headers/libraries. POSIX builds
need pkg-config; MSVC needs `CURL_ROOT` and the shared libcurl DLL directory on
`PATH`.

```sh
jpm --local --cflags=-std=c99,-DSQLITE_ENABLE_FTS5 deps
jpm --local install
```

For MSVC use `--cflags=/nologo,/MD,/DSQLITE_ENABLE_FTS5` instead. SQLite is built
with FTS5. Build CI covers Linux, macOS and Windows on x86-64 and ARM64.

Jpm's `--local` flag creates `jpm_tree/bin`, `jpm_tree/lib` and `jpm_tree/man`.
Without it, Jpm uses its configured prefix. `project.janet` copies `src`,
`zinc.md`, model presets/lockfile, stopwords and the Cygnet index builder beneath
`lib/zinc`; native dependencies live alongside that directory. `.manifests` is
Jpm bookkeeping, not Zinc state. Zinc does not build an executable.

A checkout descriptor selects `sourceDir: /runtime/zinc`, `entryModule: zinc.md`,
`entry: self`, and `dependencies.library: /runtime/zinc/jpm_tree/lib`. For an
installed package, select `sourceDir: /runtime/jpm_tree/lib/zinc` and the same
library root. Use the matching PA protocol-3 executable and sources.

PA's `janet-toolchain-TARGET` CI tarball is an installed Janet/Jpm/PA prefix,
not a Zinc distribution. Connector's `agc` embeds only its capability proxies;
it materializes them under the deployment's `.agc/libraries`. It does not install
Zinc or its retrieval/model assets.

`models.lock` records external provenance. `tools/cygnet_index.py SOURCE OUTPUT`
verifies the pinned upstream Cygnet database and builds the format-1 runtime
index. The upstream database is not that index. Model weights and the model
server are provisioned separately; `models.ini` does not enforce every lockfile
revision. Use checksum-verified local weights for reproducible deployments.
Set `search: false` when retrieval assets are absent.

## Calls and worlds

The trusted invoker supplies authenticated `source`, `world`, absolute `store`,
and input provenance:

```json
{"text":"Investigate the implementation","request":"operation-key","author":"principal-id","at":"2026-01-01T00:00:00.000Z"}
```

Use `code` instead of `text` for direct execution. `repl: true` requires an
absolute world `file`. Each call owns an editable source snapshot and restricted
Janet environment. Root calls start at Git HEAD or explicit `revision`.

```janet
(defn double [x] (* 2 x))
(defn double [x] (* 3 x))
(def double nil)
(await (self {:text "Investigate the earlier decision"}))
```

Top-level single-name `def` and `defn` persist source immediately. Redefinition
replaces the recorded form; `(def name nil)` removes it. Other expressions
execute without becoming initialization source. Nested definitions and arbitrary
heap mutations are not source snapshots. Existing closures can retain references.
World files contain definitions, not general startup programs. Initializers run
when a branch loads; use `let` for temporary handles and effects.

One tool call continues the current environment. Multiple tool calls fork
independent siblings from one frozen source/history cut. All siblings retain the
same base revision; results do not implicitly merge their source. Text selves
use an explicitly configured `agent` profile; code selves retain the caller's.
Profiles must share source/store/world/file identity.

Only granted `save` commits:

```janet
(save "Explain the world change")
(save "Keep an earlier call" {:call 42 :branch "experiment"})
(save "Integrate" {:merge "refs/heads/self/BRANCH"})
(save "Publish" {:push true})
```

Save uses Git compare-and-swap, preserves dirty canonical files, and restricts
merges to the world file. Push additionally requires `remote`. Saving an earlier
call requires its ID; a new call does not silently select earlier edits.

## Authority and lifetime

`inference` permits model execution; `repl` permits Janet evaluation.
`capabilities` grants documented built-ins or public functions from protected
absolute library paths. An empty map grants none. `memory/expand`, `save`, and
supplied namespaces all use that map. `self`, `await`, `input` and `self/document`
are intrinsics. Generated environments receive neither private runtime
configuration nor PA spawning. Capability requests execute outside the world;
arguments and results are plain data with table prototypes removed. Functions,
fibers, channels and native handles cannot cross that boundary.

Default native restrictions include filesystem, network, subprocess, FFI,
modules, threads and environment access. Definitions update their own source
through the trusted host without native filesystem permission. Supplying a
custom `forbid` list explicitly chooses the remaining native authority. Native
filesystem/subprocess grants can bypass logical restrictions; protect libraries,
Git metadata, private stores and credentials with OS confinement. PA's protocol
output descriptor is private; ordinary process stdout cannot forge frames.

Calls share admission-anchored deadlines, work/tool budgets and parallel slots.
Waits release slots. Cancellation is cooperative and does not undo effects.
Interrupted effects remain uncertain; code is not automatically replayed.
Saved calls are reauthorized against current grants. Observation survives neither
executor death nor OS process-scope termination.

`persist: false` keeps payloads in bounded RAM journals; descendants remain
temporary. Durable controls retain only scheduling identifiers, leases, budgets
and cancellation. Temporary calls cannot be reattached. Normal cleanup removes
their source files. Explicit filesystem/Git effects, provider/Discord retention
and OS swap remain outside this guarantee.

## Memory and inspection

Chronological memory covers ordered record membership with balanced summaries.
Semantic retrieval searches originals with lexical, spelling and Cygnet
expansion, then reranks against the original inquiry. `score` is the minimum
accepted relevance score, defaults to `0`, and is provider-scale dependent.
Search divides available memory space equally between the windows; disabling it
gives chronology the whole budget. Use `memory/expand id offset` to page original
records or follow summary child IDs. Token estimates are `ceil(bytes / 4)`;
provider-reported usage is retained separately.

Each model round includes current branch source and records the exact serialized
provider request, window text/coordinates, candidates, scores and cutoff before
sending. Credentials and private transport descriptors are excluded. `views`
and `render` take `{"event":123}` identifying a model-admission event; they read
that snapshot without inference, evaluation or recomputation. Scope is enforced
against current source/world/visibility. Missing exact capture fails explicitly.
Temporary prompts are not durably inspectable.

Trusted exports also include `record`, `describe`, `document`, `models`, `events`,
`pending`, `resume`, `abort`, `task` and `invalidate`; they are not world bindings.
`record` passively stores authenticated context without executing it.
`inquiry-v3` presentation retains self branches, tool results and reasoning
visibility while hiding rerank output and summary bookkeeping. Diagnostics retain
code, message, detail and context; configured ceilings fail explicitly rather
than silently truncating. Database schema version is 1; incompatible layouts are
rejected. Preserve old stores and explicitly provision a fresh path.
