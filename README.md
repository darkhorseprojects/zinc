# Zinc

Zinc is a Janet agent package for Portable Agents. It owns `self`, task execution, file-backed worlds, private history and permission profiles. It does not depend on Connector.

There is no resident service, Unix socket, REPL relay, ledger import, Git service or public `invoke`/`eval` operation.

## Build

Use Janet 1.42+, Jpm and the matching PA executable:

```sh
jpm --local deps
jpm --local install
```

Zinc installs package sources, not an executable. Select `zinc.md` export `self` through PA's `spawn` SDK or CLI. Supply `jpm_tree/lib` as the explicit `library` dependency when using a checkout.

## Self and functions

Main input selects one of text or code, not a named-operation dispatcher:

```json
{"text":"Investigate the implementation","request":"stable-operation-key"}
```

```json
{"code":"(double 21)","request":"another-operation-key"}
```

Inside world code:

```janet
(await (self {:text "Find the earlier decision about deployment"}))
(memory/expand event-id)
```

`memory/expand` is the only exposed memory function. It accepts an event ID and returns scoped original records or summary children. Searching is an inquiry to `self`; the semantic window retrieves relevant history internally. Internal paged readers remain private to compaction.

Built-in functions are called directly. `self` admits descendant work and returns a durable Zinc handle. `await` reads a descendant outcome. PA handles remain separate, ephemeral observation handles.

`record`, `describe`, `document`, `models`, `events`, `pending`, `resume` and `abort` are ordinary package exports used by invokers. `task` is the trusted executor export, not a world binding. Generated environments receive neither PA spawning nor private runtime configuration.

## Passive context

The trusted `record` export accepts `{"records":[{"key":"external-id","author":"principal-id","at":"timestamp","text":"observed text"}]}` and returns committed `events` IDs. Repeated identical records return the same IDs; reusing a key with different content is an error.

Recording creates no turn, run, task, inference, code evaluation or background summary. Even Janet fences are stored as data. Context belongs to the configured authenticated `source` and `world`; the next new inquiry includes it within its history bounds. Running turns retain their frozen cutoffs. `record` is not a generated-world binding.

`source` is the history namespace, not the record author or a world filename. Source isolation and current execution grants remain separate. Only a new `self` inquiry asks for work or a response.

## Worlds and concurrency

Required identity is `source`, absolute `store`, and `world`. For Janet execution, set `repl: true`, an absolute `file`, `seconds`, and native restrictions in `forbid`.

Each branch captures the selected entry source at admission. Descendants inherit that source. Each execution gets a separate Janet VM in a task-owned process; siblings do not share bindings. A hard evaluation deadline affects that task, not another resident heap.

```text
admitted world entry source
          /       \
      branch A   branch B
       own VM     own VM
          \       /
        durable outcomes
           SQLite WAL
```

This is source-based branching, not an arbitrary live-heap clone. Unsaved definitions and native handles are not transferred to another process. Mutable imported files and file writes retain ordinary filesystem semantics: heaps are independent, shared files are not. There is no automatic heap merge, Git branch/worktree manager, folder snapshot or publication layer.

Edit files for durability. The next root admission captures the updated entry source. `persist: false` affects conversation history, not filesystem effects. `parent` and inclusive `memory_range` constrain history attachment and visibility, not source revisions.

Optional `instructions` points to a plain world instruction file. Prompt construction reads it without executing the world merely to discover instructions.

## Capabilities

Capabilities are supplied Janet libraries exposing documented public proxy functions:

```janet
(defn echo
  "(example/echo text) — Return text with the provided prefix."
  [text config]
  (string (config :prefix) text))
```

Provide a library and private configuration:

```json
{"capabilities":{"example":{"module":"/runtime/example.janet","config":{"prefix":"hello: "}}}}
```

Zinc discovers public callable bindings and their docstrings. It renders those interfaces generically and installs proxies in the restricted world:

```janet
(import @example)
(example/echo "world")
```

Private configuration is appended only by the trusted runtime, never exposed as a world argument. Private definitions and macros are not provided. Public proxy functions must be documented. Every execution checks the currently provided interface; changing a world binding cannot manufacture authority.

There are no process-program descriptors, function-name selectors or recursive import-delegation catalogs. Proxy libraries may cross executable boundaries; Zinc does not know their provider.

## User and agent profiles

`inference` controls agent/model-request execution. `permissions` lists built-in memory/model/work functions. `capabilities` supplies external libraries. These are distinct.

An authorized human execution may have `inference: false`, `commit: true`, and a trusted `agent` profile. Human `self` requests use that agent profile, not the user's stronger permissions. Profiles must share source/store/world/file identity. Saved work is reauthorized against current profiles.

`commit` is one optional built-in function:

```janet
(commit ["world.janet"] "Update world")
```

It spawns Git with an argument vector and explicit relative paths. It commits selected tracked files; it does not initialize repositories, stage new files, manage branches, merge or push. Normal agent configuration defaults to no commit. Users stage and manage their repository normally.

Permission bindings are not OS isolation. A world granted unrestricted native filesystem/subprocess access can bypass logical permissions. Keep runtime libraries immutable, protect private storage and Git metadata, scrub credentials, and supply appropriate OS confinement. Janet's irreversible native restrictions complement that boundary; VM separation alone is not filesystem confidentiality.

## Work and history

SQLite format 1 stores admissions, immutable events/outcomes, attempts, leases, checkpoints, images and usage. Accepted task execution can finish and commit after its PA observer dies. It cannot survive death of its own executing process or OS scope.

`parallel` bounds running tasks; waits release and reacquire slots, including recursion at one slot. `task-depth`, `task-quota` and the admission-anchored `run-seconds` bound work. Reattachment never resets deadlines. Code and arbitrary capability effects are manual-recovery work, not automatic replay.

Root inquiries attach to the latest committed event in their source/world scope, including failed and interrupted work—not only successful answers. The history cutoff is frozen at admission. Explicit `parent` and `memory_range` still constrain it; a bounded prompt is not an unbounded transcript.

Known failures are outcomes. Interrupted execution can be uncertain. Original-owner fencing allows late known completion while its generation remains valid. Abort fences scheduling and records the affected tasks in branch history. It is cooperative and does not undo effects; an external action already in flight may still finish. Completed roots remain completed.

Model requests use complete JSON responses. Complete assistant messages, tool calls/results and execution receipts are persisted; transport fragments are not events. A database insert constraint permits only explicit semantic and receipt kinds, never deltas or arbitrary emissions. Event IDs count ledger records, not conversation messages. Historical fragment rows and their IDs are retained, not relabeled as completed responses.

`events` returns bounded committed pages. Reattachment emits saved events before returning an outcome, without rerunning failed effects. Observers own delivery receipts and cursors. Zinc has no Discord acknowledgment state or catch-up queue.

Token estimates use `ceil(bytes / 4)`; provider-reported usage remains separate. Tool quota accounts full stored code/outcomes. Context and summary quotas bound chronology, retrieval and compaction. History and retrieved text are data, not instructions.

Provider URL/token configuration supports llama/OpenRouter. An optional generic `transport` library replaces HTTP transfer without exposing credentials to the world. Its `request(url, method, body, headers, config)` function returns `{:status integer :body string :error :ok}` as one bounded response; there is no chunk callback. Model selections are not additional grants. `thinking: default` leaves provider controls unspecified. Reported usage is saved even when subsequent response validation fails; missing usage remains unknown.

Semantic retrieval requires the pinned format-1 Cygnet index and stopwords. Set `search: false` without those assets. Preserve stale development databases and choose a fresh path; there is no compatibility migration.

Further contracts: [wiki](https://github.com/darkhorseprojects/zinc/wiki).
