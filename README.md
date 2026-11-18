# Zinc

Zinc executes Janet against selected bindings and evidence. It remembers actual inputs, completed outcomes, and the
unfinished computation needed to continue. It knows PA, not a connector or policy engine.

## Install

Keep the complete checkout in the agent directory: `~/.agents/zinc` on Linux, macOS and WSL, or
`%USERPROFILE%\.agents\zinc` on Windows.

```sh
git clone https://github.com/darkhorseprojects/zinc.git ~/.agents/zinc
cd ~/.agents/zinc
jpm build
```

Building requires Janet 1.42+, JPM, a C compiler, OpenSSL headers, trusted CA certificates, Python 3.11+ and Git.
`jpm build` installs pinned dependencies, including PA, into the shared user Janet module directory and builds TLS and
retrieval assets. `JANET_MODPATH`, `JANET_BINPATH`, `JANET_MANPATH`, and `PYTHON` select other shared locations/tools.
Windows uses MSVC and requires `VCPKG_ROOT`; macOS can use `OPENSSL_PREFIX`. AGC is installed separately. Neither
project installs agents through a connector or generates services.

Configuration, credentials and history are operator-owned. Build does not generate or rewrite them. Start with
`examples/ac.json`, `examples/ac.rego`, and `examples/models.ini`. Replace `${directory}` with the canonical absolute
agent directory, `${handle}` with a stable agent handle, and `YOUR_USER_ID` with your Discord user ID. Configure providers
and models. For a genuinely new database only:

```sh
jpm run init
```

Initialization is offline and refuses to overwrite existing state. Policies in one directory share its handle,
directory and store. This replacement has a different two-table layout despite retaining schema number 1. It does not
migrate old state. Existing installations require a separately authorized fresh-state cutover; do not point this runtime
at an existing incompatible store and expect conversion.

## Run

Run the independently installed processes in separate terminals:

```sh
opa run --server --addr=127.0.0.1:8181 --watch --log-level=error ac.rego ac.json
llama-server --host 127.0.0.1 --port 8000 --models-preset models.ini
agc connect .
agc run .
```

Connect a bot once; existing credentials do not need reconnecting after source updates. Zinc does not start or download
model servers. For Codex, `agc login codex` stores credentials; configure the provider's absolute `credential-command`
as `["/path/to/agc", "credential", "codex"]`. Secrets stay in the keyring, not JSON or Rego.

## Entry points and commands

The agent owns `main` and imports PA. `janet -t src/main.janet` requires `PA_HANDLE` and `PA_FRAME_BYTES`.
`invoke(input, config, imports)` receives bytes, opaque agent configuration, and callable Janet imports. PA correlates
concurrent invocations and reverse calls; it does not load agents or schedule application work.

Discovery supplies command descriptors, option schema paths, import requirements and intake limits. It grants no
authority. `prepare` translates source events and options into Zinc input and opaque configuration. `position(config)`
returns the selected configuration and `through`, the last committed coverage cursor. `append(config, {records, scan})`
commits evidence and, when supplied, a `{after, through}` coverage claim in one transaction. A stale `after` fails with
`HistoryMoved`. Records carry `key`, `author`, `at` and `text`; live append deduplicates evidence without moving coverage.
First contact does not import earlier channel history. When upgrading, previously committed evidence stays, but a feed
without a coverage claim establishes its baseline at the first new trigger. Append creates no work and does not wake an
inquiry.

Invoke starts work on an available path. Invoke with `queue: true` admits the same work on a busy path, where Zinc starts
it in order. The source is committed at admission, before waiting; execution records a start without duplicating the
source. Connector queue state is not needed.

Commands come from source, never deployment JSON:

```text
/agent /reset /models /world-point /world-view /world-inspect /render
/memory-expand /memory-summarize /memory-invalidate
```

An option-only `/agent` changes a RAM overlay keyed by agent, policy, participant and conversation. It performs no
invocation or database write. Prompt-bearing calls combine the overlay with one-shot options. Reset/restart discards the
overlay. Conversation defaults can be shared; personal path/from selections do not move other participants' defaults.
Human-facing reads may select the nearest earlier authorized ancestry point and report it. Execution, summary mutations,
and explicit subtree addresses are exact. A subtree address is `event:slot`.

`input` selects `text`, `code`, or `json`. JSON contains exactly one of `text` or `code`, with optional `path`, `from`,
`memory`, `queue`, `request`, `at`, `source`, and `images`. Direct code runs in the user VM; model-created scripts run in
the agent VM. Grant direct-code access only with appropriate user-VM restrictions. `request` deduplicates durable work;
reusing it with different input/configuration fails.

Operations include `submit`, `resume`, `read`, `cancel`, the source-owned inspection/memory commands, and `models`.
Read/cancel/resume take a `work` reference. Inspection requires `inspect`; summary mutations require the corresponding
user-VM binding. Summary commands do not invoke the conversational agent or increment the inquiry count. Render uses the
same prompt assembler in a RAM-only execution.

## Configuration and capabilities

`chat`, `rerank`, and `summary` are peer objects. Select models with `chat.model`, `rerank.model`, and `summary.model`;
reasoning belongs under `chat.thinking` or `summary.thinking`. Unsupported reasoning settings fail instead of being
ignored. Summary quotas are `summary.bytes` and `summary.max-bytes`.

Each of `vm.user` and `vm.agent` owns `bindings`, `imports`, `fs`, `http`, `processes`, and `modules`. Discord accepts
`true` or an object, including `options` containing selected schema paths. Exa/TinyFish are booleans. Named peer imports
carry `policy` and `documentation`. There is no transport-level import configuration or separate import-options object.

One effective registry supplies installation, documentation, argument checks, resources and marshaling aliases. Managed
tasks inherit their role; retained functions cannot bypass the current role's grants. `output` is private caller-supplied
plumbing, never a VM capability. This is not an OS sandbox; path checks do not provide race-safe confinement.

## Execution and recovery

One executor handles direct scripts, model-created scripts, recursive `self`, managed tasks, and temporary execution.
Model tool calls admit scripts immediately and receive one native `accepted`/`rejected` receipt per call. They do not join
script completion. Effects and script outcomes wake conversational execution independently. A provider answer does not
close an inquiry with outstanding relevant work. Summary-cache work and catch-up do not wake it.

Prints are captured per task. A script outcome contains `status`, `value`, and nonempty `output` when present; the model
and Discord receive that same outcome. Janet errors remain Janet errors: use `(doc binding)` rather than inventing APIs.

`journal(id, previous, data, image)` stores actual events and changed surviving bindings. `heads(id, point, run)` uses
integer path IDs and text world names. The predecessor is history, not exclusive ownership. A running path stores one
aggregate continuation: shared environment, fibers, locals, waits, inboxes, pending inputs and external outcomes. Saving
it does not add history. Idle paths have no machine. Completion marks the actual final response/result terminal while
clearing the running inquiry, without an empty duplicate completion record.

External calls save their intent and suspended machine, commit dispatch, perform the action, then commit the outcome
before resuming. Opening the store under compatible current authorized settings resumes saved work: recorded outcomes
are reused; undispatched calls are dispatched; dispatched calls without outcomes return `unknown`, never automatic
retries. Execution resumes inside saved fibers, not at the start of source. Pure computation since the last save may
repeat. Unfinished images require the original Janet build and runtime source.

The process owner can supply current local grants at startup via `activate(config, policy)`. Local work can resume and
queued work can drain under those grants without an observer. Imports and delivery require a live authorized attachment
for the original caller, policy and destination. Another participant cannot inherit that authority. A retained output is
not proof of Discord delivery, and delivery is not replayed automatically after restart. A work reference authenticates
nobody. Restart the host to replace its startup local grants; the connector authorizes its own actions against live policy.

`temporary: true` uses the same structures in RAM, including children and summary caches. It may read durable points but
cannot publish to their durable worlds. It has no crash recovery. External side effects still occur and are not undone.

## Worlds and multiplayer

Use `self` with `:path` to continue, `:from` to fork an exact point, or `:memory` to select evidence independently.
`self/result` reads a receipt; `self/cancel` cancels unfinished work without undoing effects. Busy paths use the ordinary
queue rule. Independent paths, scripts, effects, model requests, summaries and reranking can overlap.

One execution host owns one SQLite writer. World grants determine access; authorship is provenance, not a lock.
Participants granted the same world can share paths and memory. Private policies select separate worlds. Publication
compares the expected world head; a conflict retains its candidate image and reports the conflict. There is no automatic
heap merge or effect replay.

World images contain surviving bindings and definition provenance, not print logs, loop-local bindings or scheduler
state. `world/view` renders defining source for functions and current Janet values for data, including mutations.
`world/rewind` affects future shared readers, never external actions. Source is not a universal executable export of
arbitrary closures, sharing or cycles; the binding image preserves those.

## Prompt, memory and presentation

`agent/prompt` composes configuration/capabilities, world source, current input, valid native exchanges, chronology and
semantic originals. It excludes current/live sources from both memory views before rendering. Overlapping cached
summaries are opened into children instead of duplicating live material.

For context window `W`, percentage `p`, fixed input `F`, and output reserve `O`, both views share
`min(floor(W*p/100), W-F-O)` tokens. Fixed input plus output reserve exceeding the window is an error. Byte planning uses
an approximate four-bytes/token estimate; the complete prompt also passes the model estimator. It is not an exact
tokenizer. Over-budget prompts use coarser frontiers/fewer excerpts, never truncated originals.

Originals are immutable pages in a persistent binary carry forest, with event-local node slots and byte offsets.
Chronology reserves its minimum representation; ranked semantic excerpts share that allowance, and unused space opens
chronological children newest-first. Each selected summary gets a base ceiling and recency-weighted extra space, capped
by `summary.max-bytes`. Quotas are ceilings, not targets. Larger budgets open children instead of repeatedly lengthening
paraphrases. Originals/children or adequate cached text that already fit cause zero summary calls.

Missing necessary summaries use direct children, not repeated summaries of themselves. Installation checks UTF-8,
nonempty text, exact byte limits, savings, authorized membership, citations and unchanged direct inputs/recipe. There is
no blanket half-size rule or second certification model. Expansion is read-only. Summarize installs a representation;
invalidate clears it and dependent ancestors, cancels matching work and rejects late results. Rebuild is lazy. Originals
are never deleted. FTS indexing is incremental and scoped; stopwords, Cygnet expansion, fuzzy vocabulary search and
reranking retrieve originals hidden behind chronological summaries. There are no embeddings.

Responses API completed items commit and publish at `response.output_item.done`, before generation completion. Chat
Completions uses the earliest confirmed protocol boundary and preserves OpenRouter usage chunks. Errors, blocking,
length limits and incomplete streams do not become successful answers. Native provider conversation material is retained
as required; it is not execution replay.

Zinc emits typed data; AGC renders reasoning as quotes, responses as Markdown, Janet calls in `clojure` fences, and
results in unlabeled fences. Results reference their script output IDs. The footer carries the start event, result event
and status separately from the text. Metadata attaches to the last delivered fragment when possible. Typing follows actual
active work. No token-preview journal or second publication
path exists.
