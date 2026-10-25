# Zinc

Zinc 0.2.0 is a Janet source package for Portable Agents. It owns call-local
worlds, execution profiles, private history and bounded retrieval. Connector is
optional; Zinc has no resident service or socket.

## Install

Extract the matching `zinc-v0.2.0-TARGET.tar.gz` (`.zip` on Windows) as your
deployment's `runtime` directory: rename the extracted top-level `zinc` folder
to `runtime`, rather than nesting it under `runtime/zinc`. Linux, macOS and
Windows each have x86-64 and ARM64 artifacts. The archive contains:

```text
zinc/
  zinc.md
  models.ini
  models.lock
  src/
  lib/
  data/stopwords-iso.json
  README.md
  LICENSE
  NOTICE
```

`lib` contains only runtime dependencies: PA's Janet libraries, Remarkable,
Spork's path/codecs, SQLite and Jurl. There is no Jpm tree, static library, header,
cache, test suite or application state in the artifact. Install the matching
schema-1 `agent` separately; Zinc is a source package, not a third executable.
The normal native executor needs neither Jpm nor an external Janet interpreter
at runtime. Native extensions still require their linked system libraries,
including libcurl and, when linked dynamically, SQLite with FTS5. These are
platform-specific packages, not self-contained executables. On Windows put
libcurl's runtime DLL directory on `PATH`. World-enabled execution also requires
Git on `PATH`; merging requires Git's `merge-tree --write-tree` support. HTTPS
requires the platform's CA trust. Match the Janet ABI used to build native modules.

Select the extracted package directly:

```yaml
environment:
  JANET_PATH: /srv/agents/runtime/lib
program:
  sourceDir: runtime
  entryModule: zinc.md
  entry: self
```

Set `JANET_PATH` before loading Markdown; adding paths inside the module is too
late for its parser. Normal Janet callers import `portable-agents/markdown`
first, then import Zinc and call its byte-valued exports normally. Independent
workers use ordinary `os/spawn`, `ev/` and Zinc's durable call IDs, not PA handles.

Keep `ac.yaml`, the world and private databases outside `runtime`. The model
server preset is always `runtime/models.ini`; packaging does not start servers,
register commands, change configuration, or migrate state. Connector's `agc`
materializes its Discord library under the deployment's `.agc/libraries`.

Model weights and the Cygnet index are separately provisioned assets, not
bundled state. Keep the generated index outside `runtime`, for example
`data/cygnet.db`. `models.lock` records their provenance. The source checkout's
`tools/cygnet_index.py SOURCE OUTPUT` verifies the upstream Cygnet database and
builds the format-1 runtime index; the upstream database is not that index.
`models.ini` does not enforce every weight revision. Use checksum-verified local
weights for reproducible deployments. Retrieval requires an index and reranker;
installing an artifact does not enable or disable it.

## Build

Use Janet 1.42+, Jpm, tar and libcurl development headers/libraries. POSIX
builds need pkg-config; MSVC needs `CURL_ROOT` and its runtime DLL directory on
`PATH`.

```sh
JANET_SYSTEM_SQLITE=0 jpm --local --cflags=-std=c99,-DSQLITE_ENABLE_FTS5 deps
jpm --local run package
```

For MSVC set `JANET_SYSTEM_SQLITE=0` and use
`--cflags=/nologo,/MD,/DSQLITE_ENABLE_FTS5` instead. `package` reads
dependencies from Jpm's configured module path and writes
`dist/zinc-v0.2.0-TARGET.tar.gz` (or `.zip`). Packaging is a native Jpm task
using its configured tar command; Windows uses the bundled BSD tar for ZIP
output. Jpm's `jpm_tree` and PA's `janet-toolchain-TARGET` tarball are build
inputs, not deployment layouts. `declare-source` installs under Jpm's `zinc`
module prefix; the explicit `package` task instead assembles `build/package/zinc`
from source plus an allowlist of runtime modules and archives that directory.
PA's reusable workflow exports the pinned Janet/Jpm toolchain for those builds.
Neither toolchain nor package creation starts a service. A developer checkout
can use normal Jpm source installation; release artifacts expose Zinc at their root.

## Calls and worlds

The trusted invoker supplies authenticated `source`, `world`, absolute `store`,
and input provenance:

```json
{
  "text": "Investigate the implementation",
  "request": "operation-key",
  "author": "principal-id",
  "at": "2026-01-01T00:00:00.000Z"
}
```

Use `code` instead of `text` for direct execution. `repl.enabled: true` requires an
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
heap mutations are not source snapshots. Existing closures can retain
references. World files contain definitions, not general startup programs.
Initializers run when a branch loads; use `let` for temporary handles and
effects.

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

`inference` permits model execution; `repl.enabled` permits Janet evaluation.
`repl.functions` selects the exact callable set, including `self` and `await`.
`capabilities` supplies documented built-ins or public functions from protected
absolute Janet library paths; selecting a function still requires its grant.
`input`, `self/document`, `settings` and `resources` are data-only intrinsics.
Generated environments receive neither private runtime configuration nor host process access.
Host calls use plain data with table prototypes removed; functions, fibers,
channels and native handles cannot cross the boundary.

```yaml
repl:
  enabled: true
  functions: [memory/expand, self, await, fs/list, fs/read, http/request, process/run]
  values: [world, chat, thinking]
fs:
  workspace: { root: /srv/workspace, read: true, write: false }
http:
  docs: { url: "https://docs.example.org/api/", methods: [GET] }
processes:
  status:
    argv: [/usr/bin/git, -C, /srv/workspace, status, --short]
    env: {}
```

`(fs/list :workspace ".")`, `(fs/read :workspace "README.md")` and
`(fs/write :workspace "notes.txt" "text")` require the selected function and the
root's read/write permission. File contents are bounded UTF-8; paths cannot be
absolute, traverse parents or follow symlinks. Listing results are bounded by
`history-records` and `response-bytes`; Janet enumerates the directory before
checking those limits.

`(http/request :docs "GET" ["guide" "intro"] nil)` accepts only literal path
segments, a granted method and optional text body. Redirects and ambient proxies
are disabled. Responses are bounded UTF-8 `{status body}` values, including HTTP
error statuses. `(process/run :status)` accepts only a configured name and returns
`{exit output}` with merged, bounded UTF-8 stdout/stderr. Commands have fixed argv,
empty stdin and an explicit environment; they do not inherit provider credentials.
Executable paths must be absolute. Use tool arguments such as `git -C`, not a
process-global working-directory change.

The application schema declares host functions with `:repl {:functions ...}` and
safe named-resource fields with `:public`. Only fields annotated
`:repl {:value true}` may appear in `repl.values`; `(settings)` returns those
values. `(resources)` and the prompt use the same effective grant projection,
without process environments or private library configuration. Profiles replace
whole top-level maps, not recursively merged permissions. Omitting `self` prevents
that REPL from delegating to the configured agent profile.

Native filesystem, network, subprocess, FFI, modules, threads and environment
access are always disabled in generated evaluators; `forbid` is no longer a setting.
Definitions update source through the host. Resource roots are logical scopes,
not OS confinement: path validation cannot prevent concurrent symlink races, and
named commands retain native OS authority. Running editable scripts or build files
can grant arbitrary native execution. Isolate hostile filesystem mutation,
process descendants and network egress at the OS level. Keep private stores,
credentials, trusted libraries and Git control data outside granted roots.
PA's protocol output descriptor is private; ordinary stdout cannot forge frames.

Provider credentials use `token-env`, resolved only by trusted code. Optional
provider `models` lists exact provider-local IDs; omission permits all catalogued
models and `[]` permits none. For OpenRouter, set `token-env: OPENROUTER_API_KEY`
and provision that variable in the deployment environment. Connector no longer
owns provider authentication or transports. Credential values are not saved in
call configuration or rendered into prompts.

Calls share admission-anchored deadlines, work/tool budgets and parallel slots.
Waits release slots. Tool failures preserve prior output and return structured
errors to the model. Nonfinal generations continue; only final answer content
without pending tools completes a run. Tools stay available through the round
limit. Provider failures, deadlines, cancellation, lease fencing and exhausted
shared budgets remain terminal. Cancellation does not undo effects; interrupted
code is not automatically replayed. Saved
calls are reauthorized against current grants. Changed named-resource or provider
policies invalidate saved grants; newly added resources/functions are not acquired
by old calls. Observation survives neither
executor death nor OS process-scope termination.

`persist: false` keeps payloads in bounded RAM journals; descendants remain
temporary. Durable controls retain only scheduling identifiers, leases, budgets
and cancellation. Temporary calls cannot be reattached. Normal cleanup removes
their source files. Explicit filesystem/Git effects, provider/Discord retention
and OS swap remain outside this guarantee.

`web-search: true` enables OpenRouter's server-side search independently of Janet
execution and memory `search`. Unsupported providers reject it.

## Memory and inspection

Chronological memory covers ordered record membership with balanced summaries.
Semantic retrieval searches originals with lexical, spelling and Cygnet
expansion, then reranks against the original inquiry. `score` is the minimum
accepted relevance score, defaults to `0`, and is provider-scale dependent.
Search divides available memory space equally between the windows; disabling it
gives chronology the whole budget. Use `memory/expand id offset` to page
original records or follow summary child IDs. Token estimates are
`ceil(bytes / 4)`; provider-reported usage is retained separately.

Each model round includes current branch source and records the exact serialized
provider request, window text/coordinates, candidates, scores and cutoff before
sending. Credentials and private transport descriptors are excluded. `views` and
`render` take `{"event":123}` identifying a model-admission event; they read
that snapshot without inference, evaluation or recomputation. Scope is enforced
against current source/world/visibility. Missing exact capture fails explicitly.
Temporary prompts are not durably inspectable.

The module's `document` value contains its section-oriented prose tree.
Trusted exports also include `record`, `describe`, `instructions`, `models`,
`events`, `pending`, `resume`, `abort`, `task` and `invalidate`; they are not
world bindings. `record` passively stores authenticated context without
executing it. `inquiry-v1` presentation retains self branches, tool results and
reasoning visibility while hiding rerank output and summary bookkeeping.
Committed compaction is presented as source membership, not summarizer model
output. Background compaction may finish after observation closes; its events
remain inspectable without a notification service. Presentation is newline-delimited
application JSON written with `print`; logs use `eprint`, and returned bytes carry
the final outcome. PA only transports these streams. Accepted workers survive
caller death and closed observation; executor death requires Zinc recovery.
Configured ceilings fail explicitly rather than silently truncating. Database schema version is 1;
incompatible layouts are rejected. Preserve old stores and explicitly provision
a fresh path.
