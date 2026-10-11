# Zinc 0.2.0

## Configuration and prompts

Zinc owns engine, resident, relay and Git configuration schemas. Unknown fields are rejected. `describe` exposes complete configuration/input schemas and defaults without requiring a live world or provisioned retrieval files; execution still validates its resources.

The concise prompt outlines the selected world, its public entry/native restrictions and effective member grants. Examples follow available facilities. No resident grant means no Janet evaluation tool; read-only Git does not advertise staging or commits. Credentials and private service configuration stay outside world code and prompt text.

Model access follows configured provider catalogs/credentials and Connector's gateway grants. `chat`/`rerank` are selections, not grants; the duplicate `allowed-models` setting is removed. Saved runs containing removed fields are rejected rather than adapted.

Connector configuration 4 separates named agents and PA Imports from member/channel/guild routing policies. REPL and Git are not routing targets. Invokers derive the Import member manifest from actual grants. A ledger `program: self` reference inherits the root program and effective configuration, including request overrides.

## Worlds and interaction

`cli.janet` owns `zinc serve`, `zinc repl` and `zinc ask`. The resident module owns evaluation and request relays, not command dispatch. Worlds are ordinary source/data directories loaded into a shared Janet environment. REPL-only changes are ephemeral; edit files for durability and reload explicitly. Git commit permission remains separate from filesystem persistence.

The invoker supplies confinement, native restrictions, service grants, supervision and resource limits. Fresh evaluation relays keep task tokens and credentials outside the mutable world. Retained definitions cannot retain expired authority.

SQLite format 10 and retrieval format 4 are unchanged. Preserve incompatible databases and select a fresh path; no migration or old-configuration fallback is supplied. Safe work retains checkpoint recovery and fencing. Interrupted Janet evaluations and arbitrary Imports require reconciliation, not blind replay.
