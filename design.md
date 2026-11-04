# Zinc design

## Ownership

Portable Agents owns the version-1 message grammar and its TypeScript codec. It has no Janet host, CLI, installation
logic or database schema.

Zinc owns task admission, execution, claims, checkpoints, committed shared state, inference, memory and read-only
observation. Connector owns routing, current authority, credentials, context preparation, presentation staging and
external delivery. Connector is installed independently, outside the agent directory.

## Persistence

The execution core is events and claims. A task is an admission event; models and external operations are admissions
beneath their owning task. Each admission has at most one result. A task's latest commit contains its checkpoint and
explicit shared-value changes in one atomic record. Claims contain only the task, random fencing token and expiry.
Search is a derived memory index, not another execution-state model.

The source layout is declared in src/store.sql. Configuration and input declarations live in src/schema.janet. There is
no executable Markdown or literary-module loader. Source and native dependencies belong to each agent installation.

## Pipeline

A self invocation commits an admission and returns a receipt. A separate source run invocation starts from dispatch
intent, waits for that admission in the database, and owns scheduling for the request's task tree. Receipt delivery does
not start or gate execution. Independent run invocations coordinate through database claims and the configured parallel
limit. They do not depend on an observation process staying alive.

The inquiry commits model admission before transport and commits the normalized complete response afterward. Applying
that response atomically admits independent script tasks, records provider tool receipts, and records that the turn was
applied. Receipts say accepted, not completed. The inquiry becomes eligible when any useful descendant commit appears.
It never implicitly gathers all scripts.

Each script has its own evaluator thread and host boundary. Native ev concurrency is available within that script;
independently durable lifetime belongs to admitted tasks. Runtime bindings are not serialized. Explicit checkpoints and
shared JSON publications survive a restart. Finishing a parent is not a join or an implicit cancellation.

## Continuation

A scheduler ignores terminal tasks and live claims. It reconsiders remaining tasks, evaluates committed wait conditions,
and atomically claims eligible work. Every mutation checks the current claim inside its transaction. Expired workers
cannot publish. Dependency waits commit their condition and release their claim, then re-enter from source when ready.
Scripts must guard completed prefixes using their checkpoint.

External operations require stable application keys. Completed outcomes are reused. An unresolved attempted effect
blocks for explicit reconciliation; neither a timeout nor claim expiry proves that the effect did not occur. The resolve
entry accepts a verified outcome under the direct-execution profile. Fencing cannot undo an effect already accepted by
another system. Definitive provider and capability failures are recorded as outcomes without replacing their original
diagnostics. Interrupted calls with unknown outcomes retain their operation identity and wait for reconciliation.
An unusable model answer or a turn with no admitted tools fails the task instead of retrying inference without progress.

## Observation and delivery

Observation uses a read-only database connection and a sequence cursor. It cannot recover, execute, heartbeat or cancel
work. It can continue after the root answer while background descendants finish. This affects subscription lifetime, not
task completion.

Connector stages presentation durably before advancing its observation cursor. Delivery runs independently from
observation. An uncertain external delivery is not automatically resent and does not hold up execution or unrelated
deliveries. Source stdout is a protocol transport, never execution authority.

## Temporary sessions

Temporary execution uses the same schema in a named RAM database, with a bounded copy of the existing history at
admission. Only new temporary tasks execute there. Their commits and shared values remain in RAM; they cannot create
durable descendants. A durable caller may explicitly retain returned data and its own operation metadata.

The owning process keeps the RAM session alive independently of observer success. Losing it can lose progress and
outcomes. Temporary sessions are not automatically recreated on restart. Their handles report loss rather than replaying
effects.

## Memory and providers

Original records, authors, occurrence times, summary sources and invalidations remain available. Summaries are
independently scheduled tasks with checkpointed compression. Retrieval combines bounded lexical expansion and reranking.
Prompt reports retain exact requests, memory selections, composition and summary sources. Provider outcomes retain
normalized messages, native replay items and raw usage. Images share an explicit prompt byte budget.

Credentials are loaded by the Connector-owned helper or granted environment at use time, not stored as world state.
Saved task authority is checked against current configuration. Historical data does not grant historical authority.
