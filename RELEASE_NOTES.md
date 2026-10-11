# Zinc 0.4.0

## Worlds and interaction

Worlds are ordinary source/data directories evaluated in one resident Janet environment. Users and generated code share definitions and normal redefinitions. `zinc repl CLIENT.json` accepts Janet and `/ask`; `zinc ask CLIENT.json QUESTION` submits inference. `zinc serve SERVER.json` starts the invoker-supervised evaluator.

REPL-only mutations are ephemeral. Durable changes are file edits, versioned with normal Git. Restart loads the selected source file; there is no image reconstruction, accepted head, publication, watcher or activation operation.

## Authority

The invoker supplies mounts, native sandbox restrictions, services and resource limits. A fresh trusted relay mediates every evaluation. Private task tokens, provider configuration and PA grant descriptors stay outside mutable world code. Redefining a binding does not grant authority.

The optional Git service has separately grantable `status`, `diff`, `add` and `commit` members. Requests select repository-relative paths; commit uses `--only`. Its launcher must expose only the selected repository and immutable runtime libraries. Push, hooks and arbitrary command arguments are not exposed.

## Configuration and storage

`zinc.md` contains the concise prompt, public schema, defaults, validation and composition. Private invoker configuration requires actor, absolute SQLite store path and world identity. Provider/model grants and PA Imports replace world presets and activation permissions.

SQLite format **10** stores immutable history, task admissions/outcomes, leases, summaries and accounting. Preserve older databases and select a fresh path; no migration is supplied. World source/data and private history have separate backup lifecycles.

Safe work retains checkpoint recovery and fencing. Janet evaluation and arbitrary Imports are irreversible; interrupted effects require inspection, not automatic replay. No heap continuation or exactly-once remote-effect guarantee is provided.

Connector version-3 configuration includes an external resident socket and optional, filesystem-confined Git policy. Provision worlds and supervise evaluators before enabling routes. Deployment must keep credential-bearing runtime code immutable and outside the writable world.
