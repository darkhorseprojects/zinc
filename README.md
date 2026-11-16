# Zinc

Janet execution with granular recovery, shared bindings and selected memory.
Zinc knows PA, not a connector or policy engine.

## Install

Build Zinc with JPM. AGC connects an installed agent; it is not an agent package
manager. Neither project generates or manages OS services.

Keep the complete repository in the chosen agent directory, conventionally
`~/.agents/zinc` (`%USERPROFILE%\\.agents\\zinc` on Windows):

```sh
git clone https://github.com/darkhorseprojects/zinc.git ~/.agents/zinc
cd ~/.agents/zinc
jpm build
```

Source builds require Janet 1.42+, JPM, a C compiler, OpenSSL headers, trusted
CA certificates, Python 3.11+ and Git. `jpm build` installs pinned dependencies,
including PA, into the shared user Janet module directory and builds TLS and
retrieval assets. No separate dependency-installation command is needed.
Dependencies are not copied into the agent. `JANET_MODPATH`, `JANET_BINPATH` and
`JANET_MANPATH` select other shared locations. Windows selects MSVC flags and
requires `VCPKG_ROOT`; macOS can use `OPENSSL_PREFIX`. `PYTHON` selects Python.

Builds do not create, copy or rewrite configuration, credentials or history.
Updating an existing installation needs only `jpm build`.

For a new agent directory, place your `ac.json`, `ac.rego` and `models.ini` beside
`project.janet`; `examples/` contains starting points. In the JSON, replace
`${directory}` with the canonical absolute agent directory, `${handle}` with a
stable unique agent handle, and `YOUR_USER_ID` in both `callers` and
`routes.members` with your Discord user ID. Select your providers and models.
Initialize a genuinely new database once:

```sh
jpm run init
```

Initialization creates a fresh store and refuses to overwrite an existing one.
It does not need OPA, credentials, model servers or a running Connector. All
policies in one directory must share the same agent handle, directory and store.
One `zinc` policy is sufficient; do not create initialization or direct-code
policies merely to install Zinc. Keep its handle across renames, moves and
credential rotation. Configuration, Rego, model presets and history are local
files ignored by Git; software updates must preserve them.

Core Zinc only receives the opaque `config` value; it does not load AGC
configuration or implement policy routing. Runtime paths in JSON must be
canonical and absolute.

## Start

Install AGC separately and reuse the installed OPA and llama-server executables.
No OPA build is needed. Connect a new bot once with `agc connect .`; existing
credentials do not need reconnecting after a build or reinstall.

Run each process independently in a separate terminal:

```sh
opa run --server --addr=127.0.0.1:8181 --watch --log-level=error ac.rego ac.json
llama-server --host 127.0.0.1 --port 8000 --models-preset models.ini
agc run .
```

`models.ini` belongs beside `ac.json`, not in AGC's configuration directory.
The preset has `chat` and `rerank` models. Zinc never starts or downloads models
on invocation. For Codex or another remote chat provider, retain only the
reranker preset if local chat is unnecessary. `agc login codex` stores its
credentials; configure an absolute `credential-command` pointing to
`["/path/to/agc", "credential", "codex"]` for that provider. Secrets remain in
the keyring, never in JSON or Rego.

## Agent entry point

Run `janet -t src/main.janet` with `PA_HANDLE` and `PA_FRAME_BYTES` only when
hosting Zinc through PA. The agent exports `invoke(input, config, imports)`.
Its entry point receives ordinary PA `invoke` calls, decodes base64 input, and
builds callable Janet imports. One top-level invocation is active; managed
tasks may overlap. There is no application discovery or profile catalogue.

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
`publish` selects Zinc output categories (default: reasoning, response, tool-call,
and tool-result). Zinc supplies records containing `type`, `text`, optional
`language` and boundary `footer`; the connector owns presentation. Janet scripts
use the `clojure` highlighting language. The publication function is private to
Zinc, not exposed to either VM. Without `output`, invocation returns its terminal
value. Failures raise diagnostics without also publishing a duplicate terminal
error message.
There is no detached publication stream, preview protocol, or
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
model traces. Responses reasoning summaries are requested when supported.
Completed typed messages commit once; `(↻N)` is the store-wide inquiry index,
including recursive work. Zinc supplies metadata once per inquiry and tool
call/result; it owns history and work, while the connector formats delivery.
