# Zinc 0.2.0

## Configuration and prompts

Zinc owns engine, resident, relay and Git configuration schemas. Unknown fields are rejected. `describe` exposes complete configuration/input schemas and defaults without requiring a live world or provisioned retrieval files; execution still validates its resources.

The concise prompt outlines the selected world, its public entry/native restrictions and effective member grants. Examples follow available facilities. No resident grant means no Janet evaluation tool; read-only Git does not advertise staging or commits. Credentials and private service configuration stay outside world code and prompt text.

Model access follows configured provider catalogs/credentials and Connector's gateway grants. `chat`/`rerank` are selections, not grants; the duplicate `allowed-models` setting is removed. Saved runs containing removed fields are rejected rather than adapted.

Connector configuration 1 separates named agents and PA Imports from member/channel/guild routing policies. REPL and Git are not routing targets. Invokers derive the Import member manifest from actual grants. A ledger `program: self` reference inherits the root program and effective configuration, including request overrides.

## Stored limits and accounting

Byte limits apply to stored source, serialized input/outcome and event payloads, and decoded image bytes—not HTTP or REPL wire data. Event `estimate` measures actual stored text plus JSON data using `ceil(bytes / 4)`. Summary provenance uses `source_estimate`; estimate metadata is `token-estimate`. Tool outcomes are no longer separately truncated; the existing run-shared tool quota counts full stored source/outcome bytes across nested work and resume. Admission checks source plus existing usage; responses can exhaust the quota after completion.

`context-quota` (default 32768) replaces the separate memory, soft/hard, compaction-source and retrieval limits. Inference allocates remaining context space to chronology and enabled retrieval; compaction uses its allocated context quota and blocks only when explicitly requested. `summary-quota` (default 512) bounds synopses. `search` is a boolean, default true; disable it instead of setting a retrieval size to zero. Original previews use derived byte allowances and preserve UTF-8 boundaries. Old setting names are rejected without aliases.

The mixed byte/token `budget` and reservation ledger are removed. Provider usage remains reported tokens, with missing reports explicitly unknown. `output` remains a provider output-token ceiling. Connector's result schema matches this accounting and no longer requires an obsolete revision field.

`src/engine.janet` replaces `src/agent.janet`; `src/schema.janet` replaces `src/config.janet`. Procedural validation and reauthorization move out of `zinc.md`, leaving declarative schemas and minimal composition without validator callbacks.

## Worlds and interaction

`cli.janet` owns `zinc serve`, `zinc repl` and `zinc ask`. The resident module owns evaluation and request relays, not command dispatch. Worlds are ordinary source/data directories loaded into a shared Janet environment. REPL-only changes are ephemeral; edit files for durability and reload explicitly. Git commit permission remains separate from filesystem persistence.

The invoker supplies confinement, native restrictions, service grants, supervision and resource limits. Fresh evaluation relays keep task tokens and credentials outside the mutable world. Retained definitions cannot retain expired authority.

SQLite history and Cygnet retrieval formats use version 1 as the development baseline, matching PA protocol 1 and Connector configuration 1. History names the stored event estimate and task `retry_policy` explicitly; the model-budget column and reservation table remain removed. Preserve stale development databases and rebuild retrieval indexes when schemas change; no migration or old-configuration fallback is supplied.

Task and operation `:policy` becomes `:retry-policy`, with `retry` and `manual` replacing `safe` and `irreversible`. Retry limits, checkpoints, leases and fencing remain. `retry` permits recovery after interruption, not harmless or effect-free execution; provider requests may repeat and incur costs. `manual` and exhausted retries become uncertain. Interrupted Janet evaluations and arbitrary Imports require reconciliation, not blind replay. Connector routing policies are unchanged.
