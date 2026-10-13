# Zinc 0.2.0

## User and agent views

`inference` is an explicit execution permission. User views disable it and may delegate `self` through an invoker-owned
normal-authority agent Import. Separate residents share files, not heaps. A public resident Import manifest binds only
its granted Git operations, including `commit`; actual calls still require current evaluation authority.

The generated prompt now has compact Markdown sections and an environment-inspection hint. History and retrieved text are
separate data messages, not instructions. `thinking: default` leaves provider reasoning controls unspecified; explicit efforts are
validated without downgrade, including OpenRouter's distinction between missing and null effort lists.

## Configuration and prompts

Zinc owns engine, resident, relay and Git configuration schemas. Unknown fields are rejected. `describe` exposes complete configuration/input schemas and defaults without requiring a live world or provisioned retrieval files; execution still validates its resources.

The concise prompt outlines the selected world, its public entry/native restrictions and effective member grants. Examples follow available facilities. No resident grant means no Janet evaluation tool; read-only Git does not advertise staging or commits. Credentials and private service configuration stay outside world code and prompt text.

Model access follows configured provider catalogs/credentials and invoker-supplied gateway grants. `chat`/`rerank` are selections, not grants; the duplicate `allowed-models` setting is removed. Saved runs containing removed fields are rejected rather than adapted.

Zinc is a PA package, not a CLI or executable. Jpm installs package sources only. All members, including `src/repl.janet` member `serve`, run through PA's `agent` CLI or SDK. Invokers derive the Import member manifest from actual grants and supply the ledger with the root Program and effective configuration. Deployment references and routing belong to the invoker.

The standalone client and executable declaration are removed. The downstream deployment example lives in Agent Connector, and Zinc CI no longer checks out, builds or pins Connector.

## Stored limits and accounting

Byte limits apply to stored source, serialized input/outcome and event payloads, and decoded image bytes—not HTTP or REPL wire data. Event `estimate` measures actual stored text plus JSON data using `ceil(bytes / 4)`. Summary provenance uses `source_estimate`; estimate metadata is `token-estimate`. Tool outcomes are no longer separately truncated; the existing run-shared tool quota counts full stored source/outcome bytes across nested work and resume. Admission checks source plus existing usage; responses can exhaust the quota after completion.

`context-quota` (default 32768) replaces the separate memory, soft/hard, compaction-source and retrieval limits. Inference allocates remaining context space to chronology and enabled retrieval; compaction uses its allocated context quota and blocks only when explicitly requested. `summary-quota` (default 512) bounds synopses. `search` is a boolean, default true; disable it instead of setting a retrieval size to zero. Original previews use derived byte allowances and preserve UTF-8 boundaries. Old setting names are rejected without aliases.

The mixed byte/token `budget` and reservation ledger are removed. Provider usage remains reported tokens, with missing reports explicitly unknown. `output` remains a provider output-token ceiling.

`src/engine.janet` replaces `src/agent.janet`; `src/schema.janet` replaces `src/config.janet`. Procedural validation and reauthorization move out of `zinc.md`, leaving declarative schemas and minimal composition without validator callbacks.

## Worlds and interaction

The resident module exposes ordinary PA service members. The invoker owns interaction and controller/worker supervision. A watchdog failure is a PA terminal error; the controller can exit zero after reporting it, so resident supervision must restart after service termination rather than only nonzero controller exit. Worlds are ordinary source/data directories loaded into a shared Janet environment. REPL-only changes are ephemeral; edit files for durability and reload explicitly. Git commit permission remains separate from filesystem persistence.

The invoker supplies confinement, native restrictions, service grants, supervision and resource limits. Fresh evaluation relays keep task tokens and credentials outside the mutable world. Retained definitions cannot retain expired authority.

SQLite history and Cygnet retrieval formats use version 1 as the development baseline, independently of PA's protocol version or an invoker's configuration version. History names the stored event estimate and task `retry_policy` explicitly; the model-budget column and reservation table remain removed. Preserve stale development databases and rebuild retrieval indexes when schemas change; no migration or old-configuration fallback is supplied.

Task and operation `:policy` becomes `:retry-policy`, with `retry` and `manual` replacing `safe` and `irreversible`. Retry limits, checkpoints, leases and fencing remain. `retry` permits recovery after interruption, not harmless or effect-free execution; provider requests may repeat and incur costs. `manual` and exhausted retries become uncertain. Interrupted Janet evaluations and arbitrary Imports require reconciliation, not blind replay.
