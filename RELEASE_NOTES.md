# Release notes

`jpm build` installs pinned dependencies into the shared user module directory and builds Zinc. PA does not need a
separate installation. `jpm run init` initializes a genuinely new database offline and refuses to overwrite one.

The setup wrapper and all service generation are removed. Build and initialization do not generate configuration.
Agent-local `ac.json`, `ac.rego`, `models.ini`, credentials and history remain operator-owned. Run OPA, llama-server
and AGC independently.

Terminal errors, scoped capabilities, PA framing, identities, versions and persistence schemas are unchanged.
