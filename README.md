# Zinc

Zinc is a durable Janet machine. Append committed facts, resume complete checkpoints, and derive everything else.
Portable Agents supplies framing; Connector hosts the Janet process and owns external routing and delivery.

```text
Connector ──PA──► application bindings ──► single journal owner
                                               │
                                 ┌─────────────┴─────────────┐
                                 │                           │
                           Janet workers                effect workers
                           managed tasks                actual external I/O
                                 │                           │
                           complete images                 receipts
                                 └─────────────┬─────────────┘
                                               │
                                        committed journal
                                  paths / worlds / views / output
```

## Install

Use Janet 1.42+, JPM, a C compiler, OpenSSL headers, trusted CA certificates, Python 3.11+, and Git. Install the local
`portable-agents` checkout with `jpm deps` and `jpm install`, using JPM's normal shared module directory. Set `JANET_PATH`
when that directory is not the runtime default.

Clone Zinc into `~/.agents/zinc` (`%USERPROFILE%\.agents\zinc` on Windows), preserving the repository layout. Shared runtimes,
libraries, and Connector do not belong in the agent checkout. Another clone or Git worktree creates another installation;
give a new agent a new handle and store. Moving an existing agent retains its identity but does not preserve grants automatically.

```sh
JANET_SYSTEM_SQLITE=0 jpm --cflags=-std=c99,-DSQLITE_ENABLE_FTS5,-DSQLITE_USE_URI=1 deps
jpm build
```

SQLite needs FTS5. The build prepares retrieval assets and the pinned TLS cancellation fix. On Windows use MSVC flags
`/nologo,/MD,/DSQLITE_ENABLE_FTS5,/DSQLITE_USE_URI=1`; Jsec uses `VCPKG_ROOT`. Nonstandard macOS OpenSSL installs use `OPENSSL_PREFIX`.

Copy `examples/ac.yaml` to `ac.yaml`, select the actual model ID and routes, then use Connector:

```sh
agc init DIRECTORY
agc check DIRECTORY
agc connect DIRECTORY
agc run DIRECTORY
```

The example uses a running llama.cpp server. The checkout is the installed agent; do not `jpm install` Zinc. Writable
history belongs under `${instance}`; `${directory}` is the independent working repository. No dependency tree is installed
inside the agent. Credentials are resolved by the configured environment variable or credential command, never by an image.

## State and lifetime

- A **path** is a durable address for evolving work.
- A **point** is an immutable complete checkpoint of a path.
- A **request** is one admitted input with one terminal receipt.
- A **task** is a concurrent Janet fiber inside a request.
- An **effect** is an operation outside the checkpointed machine.
- A **world** names an immutable heap revision.
- A **view** freezes memory membership.

The only authoritative store is the append-only `journal(sequence,key,kind,data,image)`. Admissions retain ownership and a
queue boolean. Path/world heads are the latest corresponding records. Queues, summary caches, and output streams are
derived journal queries; they have no separate mutable tables. Internal sequence numbers establish order, never visibility.
A separate SQLite ownership lock prevents two execution hosts from opening one persistent store and is released on process exit.

A request settles after its root function and all managed local tasks settle, including world publication or a publication
conflict. Child paths created through `self` are independent; explicitly await their requests when their answers are needed.
Later input creates another request on the same path. Completed requests never wake themselves because evidence was appended.

## Janet execution

```janet
(def a (async (fn [] (http/request "reports" "GET" ["a"] nil))))
(def b (async (fn [] (http/request "reports" "GET" ["b"] nil))))
[(await a) (await b)]
```

`async` returns a local task reference. Tasks share one heap; their fibers, closures, locals, shared references and waits
are marshaled together. Task references are scoped to their request. `await` returns a value or raises the recorded failure.
Unobserved local-task errors fail request settlement.

The machine yields before host operations. The journal owner commits the suspended image, operation intent, and buffered
output together before external dispatch or publication. A receipt is committed before the waiting task resumes.

Raw `ev/*`, filesystem/network/process handles, FFI, module loading and interpreter-environment access are not script
capabilities. Native event-loop objects stay in workers. Pure Janet functions/macros and the selected documented bindings
are available; `(doc name)`, `(input)`, `(settings)`, and `(resources)` describe the environment. Custom trusted Janet
functions are configured as external `modules` bindings with `module`, `export`, and `doc`, not injected as hidden I/O.

Checkpointing works at managed suspension boundaries inside functions and loops, not at every instruction. Pure work
since the last committed boundary may repeat. Unsupported reachable values, C-stack suspensions, quota violations and
runtime mismatches fail explicitly before an uncommitted operation can dispatch. Native images require their original
Janet version/build/configuration and Zinc runtime source. There is no source-replay or weaker execution fallback.

## Recursion and ordering

```janet
(def child (self {:text "Investigate the failed deployment."}))
(await (child :request))
(self {:path (child :path) :text "Verify the rollback." :queue true})
(self {:from historical-point :text "Consider the alternative." :memory selected-view})
```

`self` runs this same agent on a child path, not another PA agent. Exactly one of `text`/`code` is required. `path` continues
an existing path; `from` creates another path from a historical point. They are mutually exclusive. Without either, a new
child inherits the caller's current checkpoint and view. Forking starts new submitted work, not historical instructions.
Automatic crash recovery resumes the actual saved continuation.

An existing path runs one top-level request at a time. `queue: true` appends behind earlier requests on that path. On new
children, it orders queued siblings in the calling request. Unqueued children remain concurrent. Busy-path submissions
without queuing fail with `PathBusy`. Queuing changes order, not memory. Owner submissions default to the configured
`queue` boolean; native `self` children are unqueued unless requested.

`result` reads a receipt without waiting. `cancel` cancels a request and owned descendants, including descendants of
completed intermediate requests; it cannot undo external actions. Handles identify paths and requests, not authors or
credentials. The host authenticates callers. Recursive actions are newly authored by the agent while retaining their
root ownership boundary.

## Worlds and memory

Worlds publish immutable native environments through a revision comparison. Changed environments publish only after
local tasks settle. A conflict retains the candidate and fails settlement without merging heaps or replaying effects.
A granted shared world is a shared heap, not a per-author confidentiality boundary.
`world/view` shows the pinned revision and defining source provenance, not exact mutable values.

`world/set {:point p :world "main"}` requires a rewind grant and writes a new revision using an old image. Old requests
retain their pinned revision; stale publication conflicts. Rewind does not cancel work, resume old instructions, erase
history, or undo effects. Cancellation remains explicit. `world/remove` removes a local binding by symbol.

```janet
(def v (memory/view {:include [point-a point-b source-reference]}))
(self {:text "Follow this goal." :memory v})
(memory/expand v)
(memory/summarize {:view v :text "The actual summary text."})
(memory/invalidate summary-reference)
```

Points, goal text, and memory membership are independent. A reference is not permission. Expansion, summaries and
retrieval use the same authorized originals. Views union sources in supplied order with deduplication, not numeric ranges.
Immutable UTF-8 pages form a persistent binary forest. Summaries are generated lazily and keyed by exact sources, recipe
and relevant invalidations. Expansion returns originals, not generated text. Manual summaries are stored unchanged;
automatic summaries must shrink their inputs. Invalidating a summary changes its path's view and dependent representations.

Semantic retrieval retains scoped FTS, stopwords, Cygnet concept expansion, fuzzy terms, reranking, cutoff and budget
selection. Configure `rerank` before enabling `memory-retrieval`; the sample disables it until a reranker is selected.
Matching rerank manifests reuse committed results. Model effects retain exact wire requests and prompt-composition
manifests for inspection. Retrieval scores are provider scores, not probabilities. Token estimates are conservative estimates.

## Models and authority

One model interface supports `chat-completions` and `responses`. OpenAI, OpenRouter and llama.cpp are configured endpoints,
not separate schedulers. A provider has `url`, `protocol`, optional `chat-path`/`rerank-path`, `headers`, `parameters`, and
one credential source: `token-env` or an absolute `credential-command` returning a JSON header object.

`models` explicitly declares allowed IDs and their capabilities (`role`, `context`, `tools`, `parallel`, `images`,
`control`, `efforts`, `reasoning-required`, `output`, `output-field`). Alternatively, `catalogue` supplies `chat`/`rerank`
paths; llama.cpp can supply `properties: /props?model={model}`. Static declarations override discovered capabilities.
A configured catalogue is checked at application open. Model references are `provider:id`.

For OpenAI, use `https://api.openai.com`, `OPENAI_API_KEY`, and either protocol with its matching path. For OpenRouter,
use `https://openrouter.ai/api`, `OPENROUTER_API_KEY`, and `/v1/chat/completions`; native provider parameters remain explicit.
Responses endpoints requiring SSE are read through their terminal event. Provider-native reasoning/replay is retained
and reused only for the matching model and protocol. Truncated responses do not execute partial tool calls.

A `summary` object can override `chat` and `thinking`. Model `tools` expose one Janet execution tool; recursion remains
an ordinary local binding. Direct-code admission is a profile's `accept: [code]`, not an inference-disabled nested agent.
A profile granting `self` may explicitly delegate text work through the same agent's configured models.

One binding registry owns dispatch class, documentation and argument counts. `bindings` selects public capabilities;
native resource grants remain explicit under `fs`, `http`, and `processes`. A saved policy is checked against current
configured authority on resume. Revoked/changed resources fail rather than silently remap. Apply configuration changes by
restarting the host. Ephemeral profiles use a bounded-by-record-size RAM journal and disappear with their process; they
are fresh storage domains, not writable copies of another profile's history. External actions are never made temporary.

## Failure and cutover

Undispatched committed effects may execute after restart. A dispatched effect without a receipt becomes `unknown`, never
automatically resent. Timers retain recorded deadlines. Completed receipts resume the saved continuation without repeating
completed operations. EOF stops the agent process; persistent checkpoints remain, RAM journals do not. Observation and
Discord delivery have independent lifetimes and neither implies cancellation nor successful external execution.

Checkpointing is not an OS security sandbox. Filesystem grants reject observed traversal/links/reparse points, but do not
provide race-safe confinement against another process changing directories. HTTP verifies TLS and does not redirect.

This rewrite requires a fresh initialized journal and fresh Connector transport state. Stop old work and archive the old
installation before cutover. Preserve an existing agent's handle only when preserving that author identity; never silently
relabel historical authors or convert old continuations. No release number or schema number is changed. Legacy stores
are rejected, not migrated or erased.
