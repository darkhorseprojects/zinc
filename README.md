# Zinc

Janet execution with granular recovery, shared bindings and selected memory.

## Build

Requires Janet 1.42+, JPM, the installed `pa` module, a C compiler, OpenSSL headers, CA certificates, Python 3.11+ and Git.

```sh
JANET_SYSTEM_SQLITE=0 jpm --cflags=-std=c99,-DSQLITE_ENABLE_FTS5,-DSQLITE_USE_URI=1 deps
jpm build
```

Windows uses `/nologo,/MD,/DSQLITE_ENABLE_FTS5,/DSQLITE_USE_URI=1` and `VCPKG_ROOT`; macOS can use `OPENSSL_PREFIX`.
The existing build prepares retrieval assets and TLS cancellation. No streaming dependency patch is needed.
Run `janet -t src/main.janet`; the owner supplies `PA_HANDLE` and `PA_FRAME_BYTES`, then calls `app/open`.
See `examples/ac.yaml` for policy-contained deployment settings. Initialize a fresh store inside its canonical instance directory.

## State and recovery

Two tables: `journal` holds actual inputs, completed messages and evidence; `heads` maps integer paths and named worlds to
points. An unfinished path also holds one replaceable running graph: fibers, locals, pending inputs and external outcomes.
Saving that graph does not create a historical point.

Before dispatch, save the suspended machine and call arguments, then commit its dispatch marker. Save the outcome before
resuming its consumer. After a crash: reuse recorded outcomes, dispatch unstarted calls, and return `unknown` for dispatched
calls without outcomes. Never automatically repeat uncertain actions. Completed local tasks retain their results.

`temporary: true` runs entirely in RAM, including children, new memory and summary caches. It may read durable points but
cannot publish into their durable world. Restart loses it. External actions are not undone.

## Paths and worlds

```janet
(def child (self {:code "(var findings @[]) (array/push findings 1)"}))
(await child)
(await (self {:path (child :path) :code "(array/push findings 2) findings"}))
```

`:path` continues a path; `:from` starts new work from an exact historical point. `:memory` independently selects a point's
evidence. Busy paths require `:queue true`; queued siblings share their parent's ordering scope. `self/result` reads a
terminal outcome; `self/cancel` cancels unfinished descendants, not external actions.

Use `ev/go`, `ev/gather`, `ev/sleep` and `await` for managed concurrency. This is not unrestricted native event-loop access:
live sockets and C-stack fibers cannot be serialized. Granted effects perform I/O outside the machine.

World images contain surviving bindings and their definition source, not executed-script logs. Changed bindings publish
against a pinned world head; conflicts retain the local image without repeating effects. `world/remove` removes a binding;
`world/rewind point` publishes historical bindings for future readers. Ordinary execution rewind uses `:from`.

`world/view` renders actual function definitions and current data as Janet. The same renderer supplies prompt context and
owner commands. It is not a universal executable export of captured closures or cyclic heaps. Prints and loop-local bindings
are not world definitions.

Execution selectors and script operations are exact. Owner inspection commands resolve the nearest earlier point in the
selected ancestry and report the actual reference. Prompt-free configuration changes only a RAM overlay; reset clears it
without deleting history or cancelling work.

## Memory and models

Original events are paged once. A persistent binary forest stores new nodes in event-local slots, sharing prior nodes across
forks without allocating historical IDs. Chronological context lazily summarizes older subtrees. Semantic retrieval searches
selected originals hidden behind summaries using stopwords, Cygnet expansion, fuzzy FTS and reranking, not embeddings.

Summary limits are `min(summary-max-bytes, summary-bytes * (1 + floor(log2(pages))))`, additionally at most half the actual
input bytes. Oversized, incomplete or unrelated-citation output fails without truncation. Cache recipes include model settings
and child representations. `memory/expand`, `memory/summarize` and `memory/invalidate` operate on selected evidence.

One binding registry supplies VM installation, documentation and exposed resources. One prompt assembler budgets instructions,
bindings, evidence and live exchanges before protocol encoding. Token estimates are approximate; byte limits are exact.
Configure a reranker before enabling semantic retrieval.

Providers support Chat Completions and Responses with native replay preserved in model traces. Volatile previews have no
historical IDs; completed typed messages commit once, with footers at loop/result boundaries. `(↻N)` is the store-wide inquiry
index, including recursive inquiries. Progress notifications let hosts show typing without understanding execution internals.

Old schemas need an explicitly authorized fresh-history cutover; no migration or deletion is automatic. Unfinished machines
require their original Janet build and runtime source. Grants are rechecked on resume. EOF stops the process. This is not an
OS sandbox, and path checks do not provide race-safe filesystem confinement.
