# Zinc

A Janet runtime with saved execution, effects, worlds, and memory in SQLite.

## Build

Requires Janet 1.42+, JPM, the installed `pa` module, a C compiler, OpenSSL headers, CA certificates, Python 3.11+, and Git.
Set `JANET_PATH` to the shared module directory when needed.

```sh
JANET_SYSTEM_SQLITE=0 jpm --cflags=-std=c99,-DSQLITE_ENABLE_FTS5,-DSQLITE_USE_URI=1 deps
jpm build
```

Windows uses `/nologo,/MD,/DSQLITE_ENABLE_FTS5,/DSQLITE_USE_URI=1` and `VCPKG_ROOT`; macOS can use `OPENSSL_PREFIX`.
The build prepares retrieval assets and patches TLS cancellation. Run the checkout with `janet -t src/main.janet`.
The owner supplies `PA_HANDLE`/`PA_FRAME_BYTES` and calls `app/open`. Configure models and grants with `examples/ac.yaml`.
Keep history inside the canonical instance directory. New instances need new handles and fresh stores.

## Execution

A path is an integer handle to a mutable head. A point is an immutable checkpoint with a parent, machine image, and memory
root. References are local to a store, not permissions.

```janet
(let [child (self {:code "(var findings @[]) (array/push findings 1)"})]
  (await child)
  (await (self {:path (child :path) :code "(array/push findings 2) (length findings)"})))
```

`self` admits work; `self/result` reads its receipt; `self/cancel` cancels unfinished descendants. `async` and `await`
manage local tasks; `sleep` records durable delays. Native `ev/*` bindings are unavailable. `:path` continues the latest
heap; `:from` forks an exact point. They are mutually exclusive.
New input does not resume historical instructions. Recovery resumes saved fibers. Busy paths require `:queue true`.

Without a prompt, `/agent from:POINT memory:POINT` only updates the RAM overlay. Later inquiries use it until changed or
`/reset`. Inquiry-specific fields do not persist. Reset clears overrides and navigation without deleting history or
cancelling work. Commands only inspect: `world-point`, `world-view`, `world-inspect`, `memory-expand`, and `models`.

Changed heaps publish against a pinned world revision. Conflicts return `WorldChanged` with a retained candidate.
`world/point` returns the checkpoint; `world/view` renders completed Janet forms; `world/remove` removes a binding.
`world/rewind point` publishes into the current world. Ordinary rewind uses `:from`. Source rendering is not a heap export,
worlds are not confidentiality boundaries, and restoration never undoes external effects.

## Memory

Points share persistent, weight-balanced binary trees. Leaves reference source byte ranges; branches contain two child
handles and leaf count. There are no separate views or lanes. `:memory point` reuses its evidence independently of execution;
scripts can compose arrays of point/source/summary references. `memory/expand` returns originals. `memory/invalidate`
invalidates a summary on subsequent points. `memory/summarize {:point optional-point :text optional-text}` saves or generates
one explicitly.

Lazy summary budgets are `min(summary-max-bytes, summary-bytes * (1 + floor(log2(leaves))))`, with defaults 4096 and 512.
Every summary must also be at most half its actual input. Oversized or incomplete output fails without truncation.
Caches include recipe, invalidations, and enforced limit. The frontier and retrieval still share one context allowance.
Byte limits are exact; token estimates are not. Retrieval uses FTS, term expansion, and reranking; configure `rerank` first.

## Models and recovery

Providers use `chat-completions` or `responses`, explicit capabilities or catalogues, and `token-env` or an absolute
`credential-command`. References are `provider:id`; `summary` may override chat/thinking. Provider streams are assembled
before publication. Native replay stays in checkpoints. Internal summaries and encrypted reasoning are not public output.
Each completed typed message commits as one output event with an optional boundary footer. Script prints commit at managed
suspension boundaries. Footer `(↻N)` is the store-wide inquiry admission index, including child inquiries, not a model round.

Imported effects require both Connector authorization and matching Zinc binding selections. Discord additionally requires
explicit channel-method grants; enabling its import or image support alone does not grant message operations.

Checkpoints require the original Janet build and runtime source. Archive incompatible stores before fresh initialization;
there is no migration. Saved grants are rechecked on resume. Dispatched effects without receipts become `unknown`, never
automatically retried. EOF stops the process. Ephemeral journals disappear; external actions remain. Checkpointing is not
an OS sandbox; filesystem link checks are not race-safe confinement.
