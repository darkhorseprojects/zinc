# When to package

Create a package when a capability should be reused across projects or sessions.

Good reasons to package:

- reusable prompts or reference files
- reusable Circuitry graphs
- external tools that need schemas and stable names
- setup/check scripts for local capabilities
- platform-specific helpers that should not live in one project graph
- vendored third-party code that needs attribution and a clear boundary

Do not package one-off project work. Keep one-off work in the project files or a project graph.

## What a good package contains

A good package has:

- a small `zinc.pkg.yaml`
- clear prompt/file/graph assets
- explicit tool schemas
- a narrow install patch
- platform commands where needed
- a `check` script when local capabilities matter
- attribution for vendored third-party work

## Layout

Follow Zinc's project-local package layout:

- package code/assets: `.zinc/packages/<name>`
- user/project config: `.zinc/config/packages/<name>.yaml`
- package working runtime: `.zinc/runtime/packages/<name>`
- generated wiring: `.zinc/generated`

Self-contained does not mean dumping runtime files into the installed package directory. The package directory should be replaceable by `zn pkg add --replace`.

## Tool contract

A package tool should report exactly what it did.

Examples:

- process exited with code 0
- request returned status 200
- input event was sent
- file was written
- observation was captured

Those are not the same as broad task success. If success depends on external state, the model should inspect that state after the tool call.

## Avoid

- environment variables as the normal user-facing configuration path
- hidden global mutable files when project config would be clearer
- generated files inside package source
- package tools with vague schemas
- fake success messages
- package-specific behavior in Zinc core prompts or stock graphs
