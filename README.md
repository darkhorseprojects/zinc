# Zinc

Zinc is a Janet agent with a file-backed, resident REPL and chronological memory. User and agent views can share source files while retaining separate live environments and service permissions. Files hold durable code and data; ordinary Git versions those files. SQLite holds history, work admissions, outcomes and model accounting—not world images.

Zinc is a package for Portable Agents (PA), not an executable or CLI. PA transports bytes and explicitly delegated services. The invoker owns credentials, delivery, filesystem access, native facilities, service grants and process lifetime.

## Install

Use Janet 1.42+, Jpm, Git, libcurl and SQLite with FTS5/trigram support. Resident worlds require Unix domain sockets. The confinement examples use Linux and bubblewrap.

```sh
cd /srv/agents/zinc
jpm --local deps
jpm --local install
```

Jpm installs only the package sources under `zinc/`; it installs no executable. Invoke those sources through PA's `agent` CLI or SDK. The runtime contains:

```text
zinc.md                 prompt, declarative configuration/input schemas, composition
src/engine.janet        inference and durable dispatch
src/repl.janet          resident evaluator and request-scoped relay
src/schema.janet        validation, reauthorization and resident/relay/Git schemas
src/model.janet         providers and accounting
src/memory.janet        retrieval and summaries
src/store.janet         SQLite history and work
src/git.janet           optional repository-scoped Git service
```

Keep this privileged runtime and its dependencies outside the writable world. A world may contain an editable copy of its entire agent, but that copy must never supply the controller or credential-bearing services.

Database **format 1** is the development baseline. When the schema changes, preserve stale development databases and choose a fresh absolute database path; there is no migration. Create the database's parent directory yourself. Use a local filesystem with reliable SQLite locking. One history database can serve multiple actors/worlds. SQLite's `-wal` and `-shm` files are sidecars, not extra databases; do not delete active sidecars. The invoker's delivery ledger and the immutable retrieval index have separate owners.

## Create a world

Choose an ordinary directory and entry file:

```text
my-agent/
├── .git/
├── world.janet
├── world.md
└── notes.md
```

For example, `world.janet` can contain:

```janet
(def instructions (string (slurp "world.md")))
(defn double [n] (* n 2))
```

Initialize and commit with normal Git. Git is not needed to start or evaluate the world. Nothing is published, accepted or activated through Zinc.

Run one resident evaluator per logical world through the `serve` member of `src/repl.janet`. Its opaque JSON configuration contains only these service settings:

```json
{
  "file": "/world/world.janet",
  "socket": "/srv/agents/run/zinc/local/world.sock",
  "seconds": 120,
  "forbid": ["net","subprocess","ffi","modules","threads","env","asm","unmarshal","exit","locale","signal","chroot","sandbox"]
}
```

Select `src/repl.janet` and member `serve` in an ordinary PA request with empty input, then invoke `agent call FRAME-BYTES DEPTH IN-FLIGHT HANDLES ADMISSION-SECONDS`. PA wire requests encode input/configuration bytes as canonical Base64. See [Configuration](https://github.com/darkhorseprojects/zinc/wiki/Configuration) for a runnable request and confinement example. The service loads the entry once, then serves the live environment. Start the controller and its worker inside the invoker's chosen filesystem/process scope, with the world as their working directory. The `forbid` list invokes Janet's irreversible native `sandbox` before loading mutable source. It is not a filesystem jail. Do not forbid compilation or world file access if you want a usable persistent REPL.

Required resident `seconds` bounds bootstrap and each evaluation, including waits. A private native watchdog starts before sandboxing and exits the resident worker with status 124 on expiry, even for non-yielding code. PA reports a failed worker through a terminal error frame; its controller can exit zero after reporting that error. The invoker must supervise the whole controller/worker scope and restart this long-lived service after termination, provide the socket directory, remove stale sockets only after known termination, and enforce aggregate CPU, memory and process limits. Heap-only changes are lost; interrupted effects remain uncertain. Socket permissions are `0600`; they do not isolate hostile programs sharing a host user.

## Participate directly

Invoke `zinc.md` through PA's `agent call` or SDK. Member `call` accepts conversational input such as `{"text":"Add clamp to world.janet"}`. Member `invoke` accepts direct Janet input such as `{"code":"(double 21)"}`. Each uses the resident selected by its private configuration when `repl` is enabled.

The invoker selects the Program, limits, independent Spawn launcher, opaque configuration and Import grants. It derives `config.imports` from the actual grant member lists. PA does not interpret Zinc's configuration or supply an interactive Zinc client.

Grant `repl` the evaluator relay's `eval` and `document` members, delegating only `ledger` and forwarding Spawn permission for authenticated child-job receipts. Grant `ledger` Zinc's `receipt` member with the same root Program and effective configuration, its explicit service catalog and Spawn permission. These are ordinary PA descriptors; there is no Zinc-specific `program: "self"` reference. The relay configuration is only `{"socket":"/srv/agents/run/zinc/local/world.sock"}`. Supply a `library` dependency pointing to Zinc's `jpm_tree/lib` for both programs. See [Configuration](https://github.com/darkhorseprojects/zinc/wiki/Configuration) for a complete invocation.

A definition or mutable value changed only in the REPL is ephemeral. Edit the source/data file to make it durable. To evaluate edited source explicitly:

```janet
(eval-string (slurp (dyn :current-file)) world)
```

`world` is the live environment; `:current-file` identifies the entry. There is no watcher, automatic reload, evaluation-log replay or heap serialization. Restart loads the source file again. Whole-file evaluation executes effects normally and can partially change the environment before an error; it is not a transaction.

During an evaluation:

```janet
(input)
(self/document)
(await (self {:text "Investigate this subproblem" :persist false}))
(await (self/member "memory/document" "A useful observation"))
(def tool (pa/import "tool-name"))
(tool "input bytes" :member "call")
```

`self` and `self/member` return durable child handles. `await` reads their committed results. Named Imports use the ordinary synchronous PA proxy convention. `pa/imports` lists the current public names. You may redefine these bindings, but definitions cannot change actual mounts, provider permissions or delegated members.

## Inspecting and selecting a view

`(all-bindings world true)` lists local symbols; omit `true` to include inherited Janet bindings. Read the current source
with `(slurp (dyn :current-file))` when allowed. `(input)`, `(self/document)` and `(pa/imports)` expose the current request,
formatted instructions and public Import names. No credential-bearing configuration or heap/source inventory is inserted
into the model prompt.

The system document has World, World instructions, Evaluation, Members and Imports sections. History and retrieved
text are separate data messages, not instructions. The evaluation tool schema is supplied separately and is omitted when unavailable.

For user/agent separation, supervise two residents with separate sockets and the same source files. Heap changes do not
cross views; file edits do, after explicit reload. Resident `imports` is a public member manifest: a Git `commit` member
binds `(commit paths message)`; granted `status`/`diff`/`add` bind `git/status`, `git/diff`, `git/add`. Only configured bindings
appear. Actual calls still require the current relay's matching grants.

A user execution view sets `inference: false`. Its `self` binding uses a granted `agent` Import when present, returning the
normal agent's JSON result through `await`. The invoker materializes that service with the normal configuration/catalog,
not the user's. Without it, disabled inference cannot be restored by invoking another engine member.

`thinking: default` leaves reasoning to the provider. Explicit efforts are validated without silent downgrades.

## Persistence and Git permission

File persistence does not require commit permission. You can inspect and commit normally outside the evaluator:

```sh
git -C my-agent diff
git -C my-agent add -- world.janet notes.md
git -C my-agent commit -m 'Add clamp and document its boundary behavior'
```

Optionally grant `git` selected members of `src/git.janet`: `status`, `diff`, `add`, `commit`. Every request selects explicit relative `paths`; `commit` also requires `message`:

```janet
(def git (pa/import "git"))
(git `{"paths":["world.janet","notes.md"]}` :member "status")
(git `{"paths":["world.janet","notes.md"]}` :member "add")
(git `{"paths":["world.janet","notes.md"]}` :member "diff")
(git `{"paths":["world.janet","notes.md"],"message":"Add clamp and explain boundary behavior"}` :member "commit")
```

Stage new files before inspecting the `HEAD` diff. Commit uses `--only`, excluding unrelated staged paths. Inspect the actual diff and use a message describing it. Concurrent edits still require ordinary Git coordination; Zinc does not freeze a reviewed diff. No arbitrary Git arguments, hooks, push or remote operation is exposed.

Run the Git service in a filesystem view limited to this repository and immutable runtime libraries. Relative-path validation alone is not confinement against mutable-path races. Protect `.git` from world writes when commit permission is withheld; keep credentials out of readable Git metadata. The invoker owns repository initialization and local author configuration; use plain metadata without external filters or signers.

## Authority and deployment

“Empty”, “configured” and “unrestricted” describe invoker policies, not privileged Janet definitions. An empty native view can still allow world file persistence. Configured views add selected facilities and Imports. Unrestricted views may expose the entire editable agent directory. None implicitly exposes private configuration or credentials.

Each evaluation gets a fresh relay. Its task token, lease coordinates, provider configuration and actual PA grants remain in trusted processes outside the resident world. Retained definitions and proxies use the current evaluation's authority; disconnected or expired relays cannot authorize later effects. Bootstrap has native filesystem authority but no evaluation-scoped services.

Deployment configuration belongs to the invoker, not this package. Provision the world and resident socket before invoking it. Choose actor/world identities deliberately for isolation or sharing. Git is not granted by default; include it in actual Import grants and ledger delegation only when intended.

Use narrow mounts and scrub ambient credentials. The resident evaluator may use a separate network namespace because it communicates over a filesystem Unix socket. PA-controlled service workers must share their controller's loopback namespace; confine a Git worker's filesystem and PID view without independently unsharing its networking.

## History, models and recovery

Private configuration requires `actor`, absolute `store`, and `world`. Provider endpoints/credentials determine model access; `chat` and `rerank` select models from their catalogs. An invoker-supplied model gateway may narrow exact model grants. Zinc has no duplicate allowlist. `describe` returns complete configuration/input schemas, defaults and exposed parameter metadata without opening a world or requiring retrieval assets. Runtime calls still validate provisioned assets. For an installation without semantic retrieval, set `search: false`.

`document` renders the effective world's identity, resident entry/native restrictions, granted Zinc members and Import members. Examples appear only for available facilities: no REPL means no Janet tool or REPL examples; read-only Git has no staging/commit guidance. Native write/read restrictions suppress persistence/reload examples. `capabilities` narrows world-facing Zinc members. Credential values and private service paths are not printed.

`call` performs inference; `invoke` accepts either Janet `code` or a qualified `capability` and `arguments`. Other public entries are `describe`, `document`, `models`, `events`, `pending`, `resume`, `abort`, and `supervise`. `run-task` and `receipt` are trusted execution plumbing, not world-facing grants.

A minimal conversational input is `{"text":"Investigate this","parent":0}`. `parent` is an event attachment. `memory_range` contains inclusive `start`/`end`; both zero disable inherited history. Images are canonical Base64 records with `type` and `data`.

History retains immutable originals, summary ancestry, scoped FTS/trigram retrieval, bounded UTF-8 handles and chronological compaction from original sources. Semantic retrieval needs absolute `cygnet`/`stopwords` paths. `models.lock` pins the Cygnet source and stopword artifacts; build a new format-1 graph index with `python3 tools/cygnet_index.py SOURCE.db data/cygnet.db`.

Stable request keys deduplicate identical admissions and reject conflicting reuse. Tasks retain an explicit `retry-policy`: `retry` permits checkpoint recovery within the retry count; `manual` prevents automatic replay after interruption. Janet evaluations and arbitrary Imports use `manual` and become uncertain; exhausted retries also become uncertain. Retry permission does not mean harmless or effect-free: provider requests may repeat and incur costs. Inspect receipts before repeating effects. No heap continuation, rollback or exactly-once external-effect guarantee is provided. Waiting releases execution slots, including recursive work at `parallel=1`.

Independent accepted work can outlive its observer, provided the invoker keeps the evaluator, services and grants alive. Zinc tracks durable task IDs, not PA's ephemeral handles. `run-seconds` defaults to 900 and fixes the run deadline at admission; descendants, retries, resume and observation do not extend it. Reauthorization may shorten it. Expiry prevents claims, checkpoints and renewal, cancels never-started work and makes interrupted work uncertain without replay. An original fenced owner may still commit a late known result. `pending` recovers stale work and reports request/run/task IDs, state, attempt, retry policy and run/lease expiry.

The invoker supplies separate sessions and bounded worker/independent-controller launchers; PA framing/admission limits do not terminate runaway processes. Observers may reattach the original request rather than implicitly invoking `resume`. Failed, uncertain, cancelled or expired work requires inspection. Cancellation is cooperative and does not undo effects. The final inference round has no tools.

Byte limits govern stored payloads, not HTTP or REPL transport. `source-bytes` limits stored Janet source; `request-bytes` limits serialized inputs/admission payloads; `response-bytes` limits serialized outcomes/event payloads; `image-bytes` limits decoded image bytes per request. Event accounting measures the actual stored text and JSON data, with no fixed overhead estimate.

`tool-quota` retains the shared per-run estimate: sum `ceil(source bytes / 4)` and `ceil(serialized outcome bytes / 4)` for all admitted evaluations, including nested branches. Results are stored and exposed without a separate tool-result truncation. Admission checks existing usage plus the new source; completed responses can exceed the quota and block subsequent admissions. Resume retains usage; a new root run starts a new quota. Internal Imports/members are not separately charged.

`context-quota` defaults to 32768 estimated tokens and replaces the separate memory, soft/hard, source and retrieval limits. Inference deducts instructions/question overhead and provider capacity, then splits remaining space between chronological memory and enabled semantic retrieval. Compaction uses the allocated context quota; explicit blocking compaction waits for summaries. Preview limits are derived byte allowances with UTF-8 boundaries preserved. `summary-quota` defaults to 512 estimated tokens and bounds each synopsis; `search` defaults to true and controls retrieval.

Stored/projection estimates are named `estimate`; summary provenance records `source_estimate`. All estimates use `ceil(bytes / 4)`, not provider tokenization. Terminal `context_unit` and memory `unit` identify this measure as `token-estimate`.

Provider-reported usage is recorded in tokens; missing reports remain unknown. `output` is a provider output-token ceiling. There is no model `budget` or mixed byte/token reservation ledger.

Further contracts: [wiki](https://github.com/darkhorseprojects/zinc/wiki).
