# Zinc design

## Ownership

Portable Agents loads trusted modules, provides ordinary command-backed imports and
carries bounded bytes across a process boundary. Zinc owns execution, binding images, history, memory and Git checkpoints.
Connector owns identity, authorization, admission, presentation, delivery and provider credentials. Zinc owns inference
protocols, not provider identities; URLs, discovery, capabilities and wire settings are configuration.

Each persistent agent has its own canonical directory, ac.yaml, history database,
world repository, Connector ledger and Discord bot credential. Only immutable
versioned packages and assets are shared. Temporary instances have the same layout;
their creator owns joining accepted work and removing the directory. This is not
`:persist false`, which selects RAM call payloads within an existing instance.

## Worlds

The instance head is the latest successfully published durable root image. A call
has its own branch head. Parallel children fork one snapshot and never merge
implicitly. Explicit revisions stay pinned. Ordinary queued roots refresh from the
instance head when execution starts. One durable root owns the world at a time,
including while waiting for children.

Janet binding graphs, including vars, functions, macros, closure state, mutations,
aliases and cycles, are native images. Initializers execute once, not on loading.
The authorized evaluator base is rebuilt and resolved through an image registry;
credentials, channels, I/O and invocation configuration are not world state.
Unsupported values fail snapshotting. Images require a matching format and runtime.

A working candidate remains private until evaluation succeeds. Failure discards
only that candidate. Cancellation retains earlier publications. Neither rolls back
external effects. A save is an explicit Git checkpoint, not a prerequisite for
retaining successful work. SQLite's descriptor is authoritative; Git holds pinned
immutable image blobs. The worktree image is a checkpoint artifact, not another head.

`world/view` reports Janet definition forms for live bindings, image identity,
checkpoint and dirty status. Source is provenance, never executable persistence;
initializers do not replay. Images without
recorded source require explicit annotation, not decompilation or guessed code.
`world/save` commits. `world/discard` and `world/switch` replace the environment and
end the evaluation. `world/remove` deletes a binding; assigning nil does not.
The external world entry uses the same operations as evaluated Janet.

`world-bytes` limits serialized state, not heap memory. Use OS confinement for
hostile workloads. `source-bytes` limits submitted code. Zero means unlimited only
on fields explicitly marked as such; leases and shutdown bounds remain finite.
The default PRNG is entropy-seeded per invocation. Persist an explicit `math/rng`
object for continuing deterministic random state.

## Calls and grants

Direct user code and tool code use identical publication rules and language
bindings. Named filesystem, HTTP, process and trusted module grants are checked by
the host on every invocation. Native syntax is not unrestricted host authority.
Use `self` for independent child work. It yields the calling fiber; native `ev/spawn`
and `ev/gather` provide background and joined concurrency. A call owns one evaluator
across tool rounds, and settles its native fibers before closing request authority.
An answer can render while background work continues. Failed evaluations cancel
that runtime; subsequent code loads the last publication. Active fibers/channels
are runtime state, not restartable images. Children share budgets and deadlines.
Waiting releases execution capacity, not world ownership. Runtime `repl` settings
select bindings and explicit `repl.imports`; a separate flat host catalogue defines operations and
resource permissions. Schema `visible`/`public` annotations expose only selected
settings and granted resource metadata.

Configured peer aliases are callable bindings, for example `(research request)`.
They invoke the target's public self entry under the target's own configuration,
database, world and credentials. Peer access requires reciprocal explicit trust;
source code cannot choose arbitrary directories or override target grants.
Cross-agent coordinates retain caller identity. Synchronous peers use `queue: false`:
start and claim share one transaction, or the request finishes with `AgentBusy`.
Rejected IDs cannot execute later. Nonqueued work never retries automatically;
explicit resume must also acquire ownership immediately. No peer waits for another
root's world ownership, so no distributed wait graph or ancestry list is needed.
Persistent targets render through their own bots; temporary computational agents
can render under the owning bot with a temporary identity.

## Observation and memory

Visible reasoning, streaming and parallel tool traces are retained. Presentation
coordinates identify agent, request, run, branch and caller. Delivery intents and
receipts prevent automatic repetition of uncertain external effects. Known rendered
Discord history carries presentation provenance rather than masquerading as user
conversation. Explicitly created messages have separate provenance. Application stdout
is the only presentation input; import calls carry arguments and operation coordinates,
never presentation frames or scope identities.

Durable observation can detach without cancelling execution. Resume uses the same
request ID and delivery receipts; it does not replay completed code. Temporary
payloads cannot reattach. Explicit abort cancels linked work, not unrelated agents.

Admissions prove acceptance, not execution. An admitted inference without an outcome is never automatically resubmitted;
provider usage may already have occurred. Compaction runs only when context requires it, not speculatively after answers.
Stable instructions and memory precede changing world state. Responses replay retains encrypted reasoning and native
items for the same model while all context selection and tool execution remain local. Inspect original outcomes before
repeating uncertain work. `memory/expand` exposes bounded original records.
The `views` and `render` entries use one recorded-prompt projection across protocols.
Views reports chronological and semantic windows and a composition bar; its summaries
mode shows used source trees, ranges, depths and invalidations. Render includes readable
messages and the exact recorded request. Selected original images share a bounded
prompt image budget, with current inquiry images first and omissions labeled. Source submissions remain in event history, not in
executable persistence. Historical images do not grant historical authority.

## Janet documentation

Use Janet's own documentation, available inside the evaluator:

    (doc math/rng-int)
    (doc "string/")
    (doc-of string/join)

`doc*` is the functional documentation interface. `describe` prints a value's
representation, not its usage. Do not use Clojure spellings such as `concat`,
`println` or `str`; consult the native binding documentation instead.
