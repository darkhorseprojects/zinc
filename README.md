# Zinc

Zinc is a Janet inference engine with scoped recursive execution, persistent SQLite worlds, and chronological memory. Portable Agents (PA) runs programs and carries explicit Imports. Agent Connector owns Discord routing, credentials and delivery.

## Package

```text
zinc.md
src/
  agent.janet
  model.janet
  store.janet
  memory.janet
  world.janet
  worker.janet
worlds/
  empty.md
  configured.md
  unrestricted.md
```

`zinc.md` composes the schema, document, worlds and public operations. Agent owns admissions and bounded dispatch; model owns providers and billing; store owns SQLite facts; memory owns retrieval and summaries; world owns definition/state composition and code activation. Worker is the isolation boundary for generated Janet.

No Lua runtime, vector database, world Git repository, effect ledger, or continuation recovery is involved.

## Installation

Use Janet 1.42+, Jpm, Git, Python 3.11+, SQLite with FTS5/trigram, and the pinned dependencies in `project.janet`. On Linux the example worker launcher also needs bubblewrap. Clone `portable-agents`, `zinc`, and `agent-connector` as sibling directories under `/srv/agents`.

```sh
cd /srv/agents/portable-agents
jpm install
cd /srv/agents/zinc
jpm deps
```

Expose the generated `jpm_tree/lib` directory through PA's explicit `library` dependency. Commit the intended agent files before execution: workers run validated, pinned Git worktrees. Keep the checkout and dependency libraries read-only to generated code.

Database **format 9** rejects older databases. Preserve those files and select a fresh database; there is no migration or compatibility mode. SQLite must use a local filesystem with reliable locking. WAL transactions are short and do not surround HTTP calls or worker validation.

### Retrieval data

`models.lock` pins the upstream Cygnet archive and source database hashes. That source database is not the runtime graph index. Decompress the pinned source, then generate a new index:

```sh
python3 tools/cygnet_index.py /path/to/upstream-cygnet.db data/cygnet.db
```

The builder verifies the source hash and refuses an existing output. Format 4 contains 181,343 concepts, 454,427 edges and 2,513,705 forms. Provision the stopword artifact pinned in `models.lock` separately. Configure `cygnet` and `stopwords` with absolute paths.

## Invocation

PA passes opaque bytes; Zinc's public entries decode JSON. Call `describe` to obtain the actual schema and configurable parameters. User entries are `call`, `invoke`, `resume`, `pending`, `abort`, `events`, `acknowledge`, `models`, `merge-world`, `restore-world`, `reload`, and `supervise`. Durable work inspection/await is scoped through qualified capabilities.

A minimal `call` input is:

```json
{"text":"Investigate this","parent":0,"request":"stable-request-key","memory_range":{"start":0,"end":0}}
```

`parent` is an event attachment, not a code revision or world name. Zero starts a fresh conversation branch. Memory endpoints are inclusive; both zero disable inherited history. Nonzero endpoints must be ordered. Images use indexed `{mime,data}` records, with canonical Base64 data.

Configuration names the actor, repository/state/database paths, active and granted worlds, capabilities, providers, exact model IDs, quotas and bounds. Provider references have the form `llama:MODEL-ID` or `openrouter:MODEL-ID`. Zinc checks the provider's actual catalogue; aliases are not inferred. Thinking `none` suppresses reasoning observation while retaining provider replay data.

`ac.yaml` is a version-3 Connector example for `/srv/agents`. It grants a confined `worker` and trusted `ledger` with explicit member/delegation lists. Adapt paths, exact model IDs, world/capability grants, actor boundaries and resource limits before deployment. The example includes private tmpfs `/tmp` for native-library loading. Its broad read-only bubblewrap view is not a host confidentiality policy; narrow mounts, scrub credentials and impose CPU/memory/process limits yourself.

## Execution and recovery

Every recursive call, capability, Import and generated program uses the same durable job admission/outcome path. `self` spawns the same scoped instance. `self/world/put`, other qualified capabilities and named Imports admit children and return durable handles. Explicit `await` reads committed results. Children can only inherit or narrow authority; reconstruction cannot grant it.

Slots are released while waiting and reacquired before work resumes, including recursion at `parallel=1`. Completion wakes accepted queued work in the same run. Generated workers own lease renewal and fenced completion receipts, so losing an observer or launcher need not lose accepted work.

Stable keys deduplicate identical admissions and reject conflicting reuse. Immutable events and outcomes retain attempts and provenance. Safe jobs can be retried after lease expiry. Irreversible jobs become uncertain; a recorded original owner may commit a late known outcome unless superseded. Lost launch acknowledgments are ambiguity, not proof of non-execution. No arbitrary Janet VM continuation or exactly-once remote-effect guarantee is claimed.

`abort` accepts exactly one run or request key. It writes an admission tombstone even before work arrives. Cancellation is cooperative and does not undo effects already performed. An invoker must enforce hard CPU/deadline containment.

Reported provider usage is charged; missing usage keeps a conservative reservation rather than failing a successful response. Terminal agent results are immutable completion snapshots. Later maintenance charges remain in the run's usage ledger. The final permitted inference round has no tools and must explain the result.

## Worlds, history and code

Worlds contain ordered declarative definitions and state snapshots. Working images and accepted heads are SQLite facts. Empty/configured acceptance is user-triggered; agent acceptance elsewhere still requires invoker authority. Forks have independent identities and heads. Initializers cannot replay effects or start delayed work during reconstruction.

Original text/data remains available through bounded handles. Search scopes FTS5, trigram spelling and Cygnet expansion to granted history before original-query reranking. Summaries consume bounded original-source slices in chronological order, checkpoint their progress and retain immutable ancestry; they do not summarize only previews. UTF-8 reads advance whole characters and reject offsets within characters.

Git versions code and explicitly exported definitions, not evolving world state. `reload` requires `code-actions: [activate]`, materializes and validates a revision in a fresh worker, checks activation races, then appends a `code-accepted` receipt. Accepting an older valid revision is rollback. Conversations, world forks and code revisions are separate identities.

## Validation and benchmarks

```sh
export JANET_PATH="$PWD/jpm_tree/lib"
janet test/ledger.janet
python3 test/integration.py
python3 tools/benchmark.py 5
```

The integration harness needs the sibling PA checkout and bubblewrap. It creates fresh, Git-pinned packages/databases under `dist/regression-*`, runs a local JSON/SSE provider fixture, and tests isolated tools, recursion, accounting, deduplication, final-round exit, cancellation, world acceptance/fork/restore, original-source compaction and observer SIGKILL survival. Ledger probes cover scoped lexical retrieval, UTF-8 originals, summary provenance, slot release, fencing, ambiguity and late completion.

These are local fixture benchmarks, not real-model throughput measurements or cross-platform certification. Existing databases and source history are never reset by the harness.

Further contracts: [wiki](https://github.com/darkhorseprojects/zinc/wiki).
