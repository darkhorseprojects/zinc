# Release notes

Replacement runtime: one executor, aggregate saved continuations, two tables/seven columns, asynchronous script
admission, task-local output, immediate completed provider items, world-granted multiplayer, source-owned commands,
catch-up evidence, and one prompt/memory budget. Lazy binary summaries preserve originals and reject invalidated late
results. Existing state is not migrated; fresh-state cutover remains a separate operation.

`jpm build` installs pinned dependencies into the shared user module directory and builds Zinc. PA does not need a
separate installation. `jpm run init` initializes a genuinely new database offline and refuses to overwrite one.

The setup wrapper and all service generation are removed. Build and initialization do not generate configuration.
Agent-local `ac.json`, `ac.rego`, `models.ini`, credentials and history remain operator-owned. Run OPA, llama-server
and AGC independently.

PA envelopes and stable identities are retained. Package versions and schema number are unchanged; the replacement
layout is intentionally incompatible with the superseded layout.
