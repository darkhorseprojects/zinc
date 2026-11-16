# Release notes

Zinc owns setup, initialization and deployment files. `jpm setup` installs pinned dependencies into a shared user module
directory, builds the agent, and creates agent-local `ac.json`, `ac.rego` and `models.ini` without overwriting them.
`jpm init` initializes a fresh store offline, with no Connector, OPA or model server. One policy is sufficient.

Zinc's setup tool can install native user services on Linux, macOS and Windows without starting them. OPA and AGC are
existing executables, not dependencies built by Zinc. Model-server service installation is explicit.

Terminal failures remain journaled and are raised to the caller without duplicate output. Initialization does not fetch
model catalogues. Resource names exposed to the model are JSON strings. PA, schema and version numbers are unchanged.
