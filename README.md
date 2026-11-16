# Zinc

Janet execution with granular recovery, shared bindings and selected memory.
Zinc knows PA, not a connector or policy engine.

## Build and invoke

Requires Janet 1.42+, JPM, the installed `pa` module, a C compiler, OpenSSL
headers, CA certificates, Python 3.11+ and Git.

```sh
JANET_SYSTEM_SQLITE=0 jpm --cflags=-std=c99,-DSQLITE_ENABLE_FTS5,-DSQLITE_USE_URI=1 deps
jpm build
```

Windows uses `/nologo,/MD,/DSQLITE_ENABLE_FTS5,/DSQLITE_USE_URI=1` and
`VCPKG_ROOT`; macOS can use `OPENSSL_PREFIX`. The build prepares retrieval
assets and TLS cancellation. Run `janet -t src/main.janet` with `PA_HANDLE` and
`PA_FRAME_BYTES`. The agent exports `invoke(input, config, imports)`. The
process entry point receives ordinary PA `invoke` calls, decodes base64 input,
and builds callable Janet imports. It retains one active top-level invocation;
managed tasks may overlap. There is no application discovery or profile
catalogue.

`examples/config.json` is Zinc configuration, independent of any host's
deployment schema. Paths must be canonical and absolute. `initialize: true`
explicitly creates a fresh store; it never overwrites one. Handles are
provisioned by the connection owner and remain stable across configuration
changes, credential rotation, and relocation.

## Configuration and input

`input` is `text` (default), `code`, or `json`. Text enters the model loop; code
executes Janet directly in the user VM. JSON decodes a Zinc input object
containing exactly one of `text` or `code`, with optional `path`, `from`,
`memory`, `queue`, `request`, `records`, `at`, and `images`. JSON input is an
explicit direct-code capability and should not be granted to untrusted users
without suitable user-VM restrictions. The host does not interpret code fences
or Zinc's configuration.

`request` supplies an optional durable deduplication identity. Reusing it with
different input/configuration fails. `conversation` selects RAM navigation,
independently keyed by store identity and authenticated caller. `path`, `from`,
and `memory` in configuration select exact execution references. Ordinary
invocations continue their caller's selected path; resetting navigation never
deletes history.

`operation` defaults to `submit`. Other Zinc-owned operations are `reset`,
`models`, `read`, `cancel`, `resume`, `world-point`, `world-view`,
`world-inspect`, and `memory-expand`. Read/cancel/resume use a `work` reference;
model listing and inspection use `arguments`. Inspection requires
`inspect: true`; `arguments.reference` resolves the nearest earlier point in the
selected ancestry and reports that actual point. Configure these operations
through policies or call Zinc from another Janet program; they are not a shared
host application protocol.

Completed output is published through a supplied `output` function when present.
`publish` selects Zinc output categories (default: `["response"]`). Zinc renders
their Markdown and boundary footers itself; the host need not understand those
categories. Without `output`, invocation returns its terminal value. Failures
raise diagnostics. There is no detached publication stream, preview protocol, or
progress subscription.

## VMs and imports

Each of `vm.user` and `vm.agent` owns `bindings`, `fs`, `http`, `processes`, and
`modules`. Host-granted imports are ordinary Janet bindings; binding selections
determine their visibility in each VM. There is no second import manifest in
Zinc. User-supplied code uses the user registry; model-generated code uses the
agent registry. Managed tasks inherit their execution role. Effects are checked
against the executing task's role, including functions retained from another
role. Shared binding images do not grant the privileged imports used to create
them.

One registry per role supplies installation, documentation and exposed
resources. One prompt assembler budgets instructions, bindings, evidence and
live exchanges before provider encoding. Token estimates are approximate; byte
limits are exact. This is not an OS sandbox, and filesystem path checks do not
provide race-safe confinement.

## State and recovery

The schema remains two tables: `journal` contains inputs, completed messages,
evidence, and an initial identity record; `heads` maps paths and named worlds to
points. Store identity is persisted independently of its path and checked
against the owning agent handle. A running path holds one replaceable graph of
fibers, locals, pending inputs and outcomes. Saving that graph does not create a
historical point. Records distinguish authenticated ownership (`principal`) from
authorship (`author`); agent-generated records use the agent handle.

Before dispatch, save the suspended machine and arguments, then commit its
dispatch marker. Save the outcome before resuming its consumer. Recovery reuses
recorded outcomes, dispatches unstarted calls, and reports dispatched calls
without outcomes as unknown. It never automatically repeats uncertain effects.
Completed local tasks retain their results.

Work pauses without a live invocation. Resume explicitly with the original work
reference and newly authorized configuration and imports. A work reference
authenticates nobody. New invocations do not silently resume unrelated requests.
Output starts from the current journal position, not a delivery replay. Imported
functions and host routing authority are never persisted. Existing unfinished
machines require their original Janet build/runtime source; old histories
without the identity record require an explicitly authorized fresh-history
cutover. No migration, schema/version bump, or automatic deletion is performed.

`temporary: true` runs in RAM, including descendants, new memory and summary
caches. It can read durable points but cannot publish into their durable world.
Restart loses temporary state. External actions are not undone. EOF stops the
process.

## Paths and worlds

```janet
(def child (self {:code "(var findings @[]) (array/push findings 1)"}))
(await child)
(await (self {:path (child :path) :code "(array/push findings 2) findings"}))
```

`:path` continues a path; `:from` starts work from an exact historical point.
`:memory` independently selects evidence. Busy paths require `:queue true`;
queued siblings share parent ordering. `self/result` reads a receipt;
`self/cancel` cancels unfinished descendants, never external effects. A
top-level invocation waits for its descendants before releasing its imported
functions. Resume an unfinished path before submitting new work to it.

Use `ev/go`, `ev/gather`, `ev/sleep` and `await` for managed concurrency. Live
sockets and C-stack fibers cannot be saved; granted effects perform I/O outside
the machine. Worlds retain surviving bindings and definition source, not script
logs. Changed bindings publish against a pinned world head; conflicts retain
local images without repeating effects. `world/remove` removes a binding;
`world/rewind` publishes historical bindings for future readers. Ordinary
execution rewind uses `:from`. World configuration controls shared visibility;
per-caller navigation does not make a shared world private.

`world/view` renders actual definitions and data, not a universal executable
export of captured closures or cyclic heaps. Prints and loop-local bindings are
not world definitions.

## Memory and models

Original events are paged once. A persistent binary forest stores nodes in
event-local slots, sharing prior nodes across forks without historical IDs.
Chronological context lazily summarizes older subtrees. Semantic retrieval
searches selected originals hidden behind summaries using stopwords, Cygnet
expansion, fuzzy FTS and reranking, not embeddings. Configure a reranker before
enabling semantic retrieval.

Summary limits are
`min(summary-max-bytes, summary-bytes * (1 + floor(log2(pages))))`, additionally
at most half the actual input bytes. Oversized, incomplete or unrelated-citation
output fails without truncation. Cache recipes include model settings and child
representations. `memory/expand`, `memory/summarize` and `memory/invalidate`
operate on selected evidence.

Providers support Chat Completions and Responses with native replay retained in
model traces. Completed typed messages commit once; `(↻N)` is the store-wide
inquiry index, including recursive work. Zinc's output categories, footers,
memory, and work model are its own implementation, not requirements imposed on
other agents.
