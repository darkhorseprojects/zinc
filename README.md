# Zinc

A durable Janet machine with checkpointed fibers, recursive work, explicit memory, and journaled effects. It implements
Portable Agents' [application contract](https://github.com/darkhorseprojects/portable-agents/blob/main/interaction.md).
The host owns routing and delivery; Zinc owns execution and presentation meaning.

## Build and run

Requires Janet 1.42+, JPM, a C compiler, OpenSSL headers, trusted CA certificates, Python 3.11+, and Git. Install the
local PA library with `jpm deps && jpm install`. Set `JANET_PATH` to its shared module directory when needed.

```sh
JANET_SYSTEM_SQLITE=0 jpm --cflags=-std=c99,-DSQLITE_ENABLE_FTS5,-DSQLITE_USE_URI=1 deps
jpm build
```

SQLite needs FTS5. Windows uses `/nologo,/MD,/DSQLITE_ENABLE_FTS5,/DSQLITE_USE_URI=1` and Jsec's `VCPKG_ROOT`;
nonstandard macOS OpenSSL installs use `OPENSSL_PREFIX`. The build prepares retrieval assets and the existing Jsec TLS
cancellation fix. Spork is unmodified.

Run the complete checkout, not a `jpm install` of Zinc. A PA host launches `janet -t src/main.janet` with `PA_HANDLE`
and `PA_FRAME_BYTES`, then calls `app/open`. `examples/ac.yaml` contains deployment settings; choose actual models and
grants. The host expands `${instance}` and `${directory}`. Store writable history under the canonical instance
directory. New agents need new handles and stores; moving an existing agent preserves its identity, not its permissions.

## Execution

- **Path:** durable address for evolving work. **Point:** immutable checkpoint of a path.
- **Request:** admitted input with one terminal receipt. **Task:** managed fiber within a request.
- **Effect:** operation outside the checkpointed machine. **World:** pinned heap revision. **View:** memory membership.

One owner commits the append-only SQLite journal. Workers return complete images or effect receipts. `async` starts a
local task; `await` returns its value or raises its failure. Tasks share a heap and settle with their request. Child
requests are independent unless explicitly awaited. `(doc name)`, `(input)`, `(settings)`, and `(resources)` expose
grants. Raw I/O, FFI, module loading, and event-loop handles are not script capabilities. Trusted native functions use
`modules`.

## Recursion and continuation

```janet
(let [child (self {:code "(var findings @[]) (array/push findings 1) (length findings)"})]
  (await child)
  (sleep 30)
  (await (self {:path (child :path)
               :code "(array/push findings 2) (length findings)"
               :queue true})))
```

```text
parent ──self──► child request A ──finish──► saved child heap
   │                   │                         │
   └──await A◄──────────┘                         │
   └──later self {:path child}────────────────────┘
                                  └──► child request B ──► parent resumes
```

`self` runs this agent, not a peer. `path` submits new work to an existing saved heap; `from` forks an immutable point
and runs new input. Neither resumes historical instructions. Recovery resumes the actual suspended fibers and waits.
`queue true` orders existing-path requests or new queued siblings; it does not inject input into a suspended fiber. Busy
paths reject unqueued submissions. `result` reads a receipt; `cancel` includes descendants but never undoes effects.

## Worlds, memory, and models

Changed environments publish by comparing the pinned world revision. A child or concurrent path can advance that world
and make a later parent publication fail with `WorldChanged`; the candidate is retained. Keep bookkeeping lexical when
it need not become a world definition. Shared worlds are not confidentiality boundaries. `world/set` creates a revision
from a point; it does not resume instructions, cancel work, or roll back effects.

`memory/view` selects authorized sources; `memory/expand` returns originals. Summaries are lazy, source-keyed, and
invalidatable. Manual summary text is unchanged; generated summaries must shrink their inputs. Retrieval uses scoped
FTS, Cygnet expansion, fuzzy terms, and reranking. Configure `rerank` before enabling `memory-retrieval`.

Providers select `chat-completions` or `responses`, a URL, explicit capabilities or catalogue paths, and one credential
source: `token-env` or absolute `credential-command`. Model references are `provider:id`. Both protocols stream SSE;
only validated terminal tool calls execute. Native replay stays model/protocol-specific. Internal summaries and
encrypted reasoning are not public output. `summary` may override chat/thinking. Saved grants are rechecked on resume.

Zinc publishes committed response, reasoning, tool-call, and tool-result deltas. Footers appear once per model-loop or
result boundary, never per token or split: `#start (↻round) → #point · status`. Numbers are journal display labels, not
permissions. Loop status describes model completion, not request settlement; later failures appear without repeating
that loop's footer. The host buffers until explicit completion or a destination-size split. Script prints commit at
managed suspension boundaries, not during uninterrupted pure computation.

## Recovery

Checkpoints require the original Janet version/build/configuration and runtime source. Pure computation since the last
boundary may repeat. Unsupported reachable values fail before an uncommitted operation dispatches. Undispatched effects
may execute after restart; dispatched effects without receipts become `unknown`, never automatically retried. Deadlines
and completed receipts survive. EOF stops the process; ephemeral journals disappear, external actions do not.

Checkpointing is not an OS sandbox. Filesystem link checks do not provide race-safe confinement; HTTP verifies TLS and
does not redirect. Archive incompatible history before a fresh initialization; continuations are not migrated or erased.
