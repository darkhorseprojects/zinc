# Zinc

Zinc is a Janet source package for Portable Agents. It owns call-local source,
SQL outcomes, private history and bounded retrieval. It has no resident service.
Connector is optional.

## Install and build

Extract the matching `zinc-v0.2.0-TARGET.tar.gz` (`.zip` on Windows), rename its
`zinc` directory to `runtime`, and install the matching schema-1 `agent`.
Artifacts cover Linux, macOS and Windows on x86-64 and ARM64. They contain
`zinc.md`, `src`, `lib`, `models.ini`, `models.lock`, stopwords, the Cygnet tool and
notices; configuration, worlds and databases belong outside the runtime.

```yaml
source: runtime
module: zinc.md
entry: self
environment:
  JANET_PATH: /absolute/deployment/runtime/lib
transport: {frame-bytes: 16777216, admission-seconds: 10}
```

Set `JANET_PATH` before loading Markdown. Ordinary Janet callers first import
`portable-agents/markdown`, then import Zinc and call its byte-valued exports.
Native modules must match the Janet ABI and host library. On Windows, keep PA's
`janet.dll` and the DLLs from `runtime/bin` beside `agent.exe`; retain their
`runtime/share` licenses and install the matching Microsoft Visual C++ runtime.
On Linux install the distribution's libcurl runtime and CA certificates; on macOS
run `brew install curl`. Install Git on PATH and configure a Git author identity
before using `save`. Merging requires `git merge-tree --write-tree`.

Native release builds target Ubuntu 24.04/glibc, macOS 15 and Windows 11, on
x86-64 and ARM64. They are not musl builds or self-contained executables.

Building requires Janet 1.42+, Jpm, tar, a C compiler and libcurl development
files. POSIX builds need pkg-config; MSVC needs `CURL_ROOT`.

```sh
JANET_SYSTEM_SQLITE=0 jpm --local --cflags=-std=c99,-DSQLITE_ENABLE_FTS5 deps
jpm --local run package
```

For MSVC use `--cflags=/nologo,/MD,/DSQLITE_ENABLE_FTS5`. Windows release builds
use the shared Janet toolchain in PA's reusable CI workflow, not interpreter-bound
native modules from an unrelated Janet installation.

Model weights and the Cygnet index are separately provisioned. `models.lock`
records provenance; `tools/cygnet_index.py SOURCE OUTPUT` verifies the upstream
Cygnet database and builds the runtime index using Python 3.11+. The upstream
database itself is not a runtime index. Set `search: false` to run without Cygnet
or a reranker; missing search resources never trigger an automatic fallback.
Use verified local weights for reproducible deployments.

## Execution and durability

The invoker supplies absolute `store`, `source`, `world` and authenticated input:

```json
{"text":"Investigate this","request":"operation-key","author":"principal","at":"2026-01-01T00:00:00.000Z"}
```

Use `code` instead of `text` for direct Janet execution. A `repl` object enables
evaluation and requires an absolute world `file`; omit it to disable evaluation.

```janet
(defmacro twice [x] ~(+ ,x ,x))
(self {:code "(twice 21)"})
(self {:text "Investigate the earlier decision"})
```

`self` returns the completed result, not a future: evaluation text for code,
a map with `:text` for inquiries. Text uses the configured `agent` profile,
otherwise the caller profile; code uses the caller profile. Profiles share
source/store/world/file identity. Use native fibers to run children concurrently:

```janet
(ev/gather (self {:code "(+ 20 22)"}) (self {:text "Investigate independently"}))
```

Select `ev/*` to expose the native concurrency bindings. Concurrent waits release
the parent slot together; children still obey the shared `parallel` limit.
Join local fibers whose completion matters. Model multi-tool calls also fan out.

Workers own admission and completion in SQL. Spawned workers retain `:d` and
PA detachment. Losing an observer, Connector, or a local process reference does
not cancel accepted execution. Executor or machine failure requires recovery;
no live REPL heap is durable. Supervisors must not kill the containing job/cgroup.

Calls copy source, not live bindings. Root source comes from Git HEAD or
`:revision`; children copy the caller's current source. Single-name `def`, `defn`
and `defmacro` update source after successful evaluation; `(def name nil)` removes
a declaration. Other expressions execute without becoming startup source.
Initializers run on load: use `let` for temporary values and effects.

`:parent` attaches history; `:memory_range {:start id :end id}` bounds visibility.
`:parent 0` defaults to empty history, not empty source. Child edits never merge
automatically. Selected `save` commits source, not heap state:

```janet
(save "Explain the change")
(save "Keep an earlier call" {:call 42 :branch "experiment"})
(save "Integrate" {:merge "refs/heads/self/BRANCH"})
(save "Publish" {:push true})
```

Save uses Git compare-and-swap, preserves dirty canonical files and restricts
merges to the world file. Push additionally requires `remote`.

`run-seconds` bounds the tree; `seconds` bounds each evaluation including waits.
Waits release parallel slots. Descendants share work/tool budgets. Cancellation
fences subsequent operations but does not undo effects. Interrupted code is not
automatically replayed; uncertain effects require inspection.

`persist: false` keeps payloads in a bounded RAM journal. Descendants remain
temporary and cannot reattach. Controls/source can reach disk, durable callers
can retain results, and external effects retain their own behavior. Normal
cleanup removes temporary source files.

## REPL and named grants

```yaml
repl:
  bindings: [core/*, ev/*, string/*, math/*, self, memory/*, fs/*, http/*, process/*]
  values: ["*"]
  setup: /absolute/world/repl.janet
fs:
  workspace: {root: /absolute/workspace, write: false}
http:
  docs: {url: "https://docs.example.org/api/", methods: [GET]}
processes:
  status:
    argv: [/absolute/bin/git, -C, /absolute/workspace, status, --short]
```

`bindings` selects actual Janet bindings, including macros/constants, and host
functions. `core/*` selects unqualified core names; multiplication is selected
individually as `core/multiply`. Namespaced selectors such as `string/*` and `*`
expand deterministically; unknown selections fail. Admissions save exact expanded
sets, so existing calls never acquire newly added bindings through wildcards.
`values` selects only schema fields marked REPL-visible; `*` exposes all such
fields, never private runtime configuration.

Optional trusted `setup` exports `(configure env)`. It can install local bindings
and return standard `run-context` options: `:parser`, `:read`, `:expander`, and
`:on-compile-warning`. Input syntax can change while saved declarations remain
canonical Janet. Host source commits, errors, output capture and deadlines stay
Zinc-owned. Native restrictions are fixed; syntax customization never bypasses
named-resource grants.

Filesystem, network, subprocess, FFI, module loading, threads and environment
access remain disabled inside generated evaluators. Named operations run in the
trusted host, not through a generic capability module:

- `(fs/list :workspace ".")` lists bounded names.
- `(fs/read :workspace "README.md")` reads bounded UTF-8 text.
- `(fs/write :workspace "notes.txt" "text")` requires root write permission.
- `(http/request :docs "GET" ["guide"] nil)` permits only configured methods and
  literal segments; no redirects or ambient proxies. Returns `{:status :body}`.
- `(process/run :status)` runs only fixed argv/env with empty stdin and bounded
  merged output. It does not inherit provider credentials.

Paths reject traversal, links, and Windows reparse points. These are logical
scopes, not race-proof OS confinement; hostile filesystem mutation, editable
executables/build scripts and subprocess descendants require OS isolation.
Windows CRT path limitations remain; Unix modes are not Windows ACLs. Keep
stores, credentials, trusted modules and Git metadata outside granted roots.

`input`, `self/document`, `settings` and `resources` expose admitted data,
instructions, selected settings and effective named grants. Host RPC accepts
plain JSON data, not functions, prototypes or native handles. Ordinary protected
RPC libraries live in `repl.modules`; Connector supplies its Discord module there.
Saved execution is reauthorized against current grants and module/setup paths.

## Models, memory and inspection

Provider configuration grants URLs, optional exact model IDs and `token-env`
credential references. Credentials are resolved in trusted code, never saved in
configuration or prompts. `web-search` is OpenRouter provider search, independent
of memory `search`. Unsupported capabilities fail rather than falling back.

Chronological memory uses balanced summaries with source membership and
invalidation. Retrieval uses FTS, exact Cygnet expansion and reranking against
the inquiry; no spelling-correction index is maintained. `score` is the minimum
reranker score. Search splits available memory space equally; disabling it gives
chronology the full budget. `memory/expand` pages records and summary children.
Estimates are `ceil(bytes/4)`; provider usage is stored separately.

Each model round records the exact serialized request, source snapshot and memory
window coordinates before sending. `views` and `render` read that capture without
inference or recomputation. Temporary requests are not durably inspectable.
Other trusted exports include `describe`, `instructions`, `models`, `record`,
`events`, `pending`, `resume`, `abort`, `task` and `invalidate`. `record` stores
passive authenticated history, never executable turns.

Presentation is application NDJSON on stdout; logs use stderr; the final return
value carries the outcome. PA only transports bytes. Background compaction may
finish after observation closes. Limits fail explicitly instead of truncating.
**Zinc database version is 2.** Preserve old stores and provision a fresh path;
there is no migration or compatibility mode.
