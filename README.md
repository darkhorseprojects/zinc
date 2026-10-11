# Zinc

Zinc is a Janet agent with a file-backed, resident REPL and chronological memory. You and the agent evaluate code in the same live environment. Files hold durable code and data; ordinary Git versions those files. SQLite holds history, work admissions, outcomes and model accounting—not world images.

Portable Agents (PA) transports bytes and explicitly delegated services. Agent Connector supplies Discord routing, credentials and delivery. The invoker owns filesystem access, native facilities, service grants and process lifetime.

## Install

Use Janet 1.42+, Jpm, Git, libcurl and SQLite with FTS5/trigram support. Resident worlds require Unix domain sockets. The confinement examples use Linux and bubblewrap.

```sh
cd /srv/agents/zinc
jpm deps
jpm install
```

The package installs `zinc` and the following runtime:

```text
zinc.md                 prompt, configuration schema/defaults/validation, composition
src/agent.janet         inference and durable dispatch
src/repl.janet          resident evaluator, request-scoped relay and CLI
src/model.janet         providers and accounting
src/memory.janet        retrieval and summaries
src/store.janet         SQLite history and work
src/git.janet           optional repository-scoped Git service
```

Keep this privileged runtime and its dependencies outside the writable world. A world may contain an editable copy of its entire agent, but that copy must never supply the controller or credential-bearing services.

Database **format 10** rejects older databases. Preserve them and choose a fresh absolute database path; there is no migration. Create the database's parent directory yourself. Use a local filesystem with reliable SQLite locking.

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
(def instructions (slurp "world.md"))
(defn double [n] (* n 2))
```

Initialize and commit with normal Git. Git is not needed to start or evaluate the world. Nothing is published, accepted or activated through Zinc.

Run one resident evaluator per logical world. Its JSON configuration contains PA framing limits and these service settings:

```json
{
  "limits": {"frameBytes":16777216,"depth":64,"inFlight":32,"handles":4096,"admissionSeconds":10},
  "config": {
    "file": "/world/world.janet",
    "socket": "/srv/agents/run/zinc/local/world.sock",
    "forbid": ["net","subprocess","ffi","modules","threads","env","asm","unmarshal","exit","locale","signal","chroot","sandbox"]
  }
}
```

`zinc serve SERVER.json` loads the entry once, then serves the live environment. Start it inside the invoker's chosen filesystem/process scope, with the world as its working directory. The `forbid` list invokes Janet's irreversible native `sandbox` before loading mutable source. It is not a filesystem jail. Do not forbid compilation or world file access if you want a usable persistent REPL.

The invoker must provide the socket directory, supervise the process, remove stale sockets after termination, and enforce CPU, memory, process and deadline limits. Socket permissions are `0600`; they do not isolate hostile programs sharing a host user.

## Participate directly

The trusted client accepts a private PA invocation descriptor, not a world pathname:

```sh
zinc repl /srv/agents/private/local/client.json
zinc ask /srv/agents/private/local/client.json 'Add clamp to world.janet'
```

A client descriptor has `program`, `limits`, `spawn`, `config` and `imports`. Programs use PA's normal `sourceDir`, `entryModule`, `dependencies` and optional `command`. Here `config` and each Import's `config` are JSON objects; the CLI encodes them as opaque PA configuration bytes.

Grant `repl` the evaluator relay's `eval` and `document` members, delegating only `ledger` and forwarding Spawn permission for authenticated child-job receipts. Grant `ledger` Zinc's `receipt` member, the same private actor/store/world configuration as the root, and the root's explicit service catalog and Spawn permission. The relay configuration is only `{"socket":"/srv/agents/run/zinc/local/world.sock"}`. Supply a `library` dependency pointing to Zinc's `jpm_tree/lib` for both programs. See [Configuration](https://github.com/darkhorseprojects/zinc/wiki/Configuration) for a complete descriptor.

```text
zinc> (defn double [n] (* n 2))
zinc> (double 21)
42
zinc> (defn double [n] (+ n n))
zinc> /ask Add clamp to world.janet and explain its boundary cases.
zinc> (clamp 12 0 10)
10
```

Multiline Janet is accepted. `/ask` submits conversational inference; ordinary input evaluates Janet directly. Both use the same resident environment.

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

`ac.yaml` supplies Connector version-3 policies for the engine, relay and optional Git service. Before enabling a route, provision its world and resident socket. The example isolates actors by application/member/channel; intentional sharing requires a corresponding shared-world policy. Adapt exact model IDs, library paths, mounts and resource limits. The optional Git policy is not imported by default. To grant it, add a `git` Import with the desired member list and include `git` in `ledger`'s delegated catalog.

Use narrow mounts and scrub ambient credentials. The resident evaluator may use a separate network namespace because it communicates over a filesystem Unix socket. PA-controlled service workers must share their controller's loopback namespace; the Git example therefore isolates its filesystem and PID view without unsharing networking.

## History, models and recovery

Private configuration requires `actor`, absolute `store`, and `world`. Providers and exact model references grant model access. `describe` returns the schema/defaults from `zinc.md`. For a minimal installation without semantic retrieval, set `search-units` to zero.

`call` performs inference; `invoke` accepts either Janet `code` or a qualified `capability` and `arguments`. Other public entries are `describe`, `document`, `models`, `events`, `pending`, `resume`, `abort`, and `supervise`. `run-task` and `receipt` are trusted execution plumbing, not world-facing grants.

A minimal conversational input is `{"text":"Investigate this","parent":0}`. `parent` is an event attachment. `memory_range` contains inclusive `start`/`end`; both zero disable inherited history. Images are canonical Base64 records with `type` and `data`.

History retains immutable originals, summary ancestry, scoped FTS/trigram retrieval, bounded UTF-8 handles and chronological compaction from original sources. Semantic retrieval needs absolute `cygnet`/`stopwords` paths. `models.lock` pins the Cygnet source and stopword artifacts; build a new format-4 graph index with `python3 tools/cygnet_index.py SOURCE.db data/cygnet.db`.

Stable request keys deduplicate identical admissions and reject conflicting reuse. Safe work can recover from checkpoints; Janet evaluations and arbitrary Imports are irreversible and become uncertain after interruption. Inspect receipts before repeating effects. No heap continuation, rollback or exactly-once external-effect guarantee is provided. Waiting releases execution slots, including recursive work at `parallel=1`.

Independent accepted work can outlive its observer, provided the invoker keeps the evaluator, services and grants alive. Cancellation is cooperative and does not undo effects. Provider usage is recorded separately from conservative budget reservations; unknown usage retains its reservation. The final inference round has no tools.

Further contracts: [wiki](https://github.com/darkhorseprojects/zinc/wiki).
