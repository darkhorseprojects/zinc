# Zinc packages

A Zinc package is an installed capability: prompts, files, graphs, scripts, and external tools that can be wired into a project graph.

Packages are explicit. Installing a local package may patch `.zinc/graphs/zinc-loop.circuitry.yaml`, but the graph still shows which prompts and tools were added. Core Zinc installs no optional packages by default.

Official optional packages live at:

```text
https://github.com/darkhorseprojects/zinc-packages
```

## Manifest shape

Package metadata lives in `zinc.pkg.yaml`:

```yaml
name: example
version: "1.0.0"
description: Example package.

assets:
  prompts:
    example_prompt: prompts/example.md
  files:
    example_file: assets/example.txt
  graphs:
    example_graph: graphs/example.circuitry.yaml

scripts:
  setup:
    linux: scripts/setup
    macos: scripts/setup
    windows: scripts/setup.cmd
  check:
    linux: scripts/check
    macos: scripts/check
    windows: scripts/check.cmd

install:
  model:
    input:
      - prompt:example_prompt
      - file:example_file
    tools:
      - example_tool
```

Prompts are not loaded by name alone. Tools are not callable by name alone. They must be present in the graph model resource.

## Generated wiring

Local package installs write generated package resources to:

```text
.zinc/generated/packages.circuitry.yaml
```

The project loop graph imports that file and references package resources through the `packages` namespace:

```yaml
imports:
  packages: "/path/to/project/.zinc/generated/packages.circuitry.yaml"

resources:
  assistant:
    model:
      input:
        - packages.example_prompt
```

Generated files are not user-authored. Regenerate them by installing, updating, or removing packages.

## Layout convention

Use Zinc's package layout consistently:

- `.zinc/packages/<name>`: installed package code and assets
- `.zinc/config/packages/<name>.yaml`: user/project package config
- `.zinc/runtime/packages/<name>`: package working runtime
- `.zinc/generated`: Zinc-generated wiring

Installed package directories should be replaceable. Do not put venvs, compiled helpers, downloaded working files, or user choices inside `.zinc/packages/<name>`.

Packages can be self-contained while still following this layout: vendor code and scripts inside the package, create working environments under runtime, and read user choices from config.

## Handlers and scripts

Package tool handlers are external only:

- `process`
- `http`
- `mcp`

Graph execution stays built into Zinc through `run_graph`.

Package scripts run with `zn pkg exec`; they are setup/check/maintenance commands, not model tools.

Package hooks are event hooks. Hook scripts may return declared package events, but Zinc owns validation and appending into the core runtime event log. Hooks should not pretend to mutate sessions directly.

## Author rules

- Keep the manifest small and readable.
- Use platform-specific commands where needed.
- Include a `check` script when setup depends on local capabilities.
- Prefer config files over environment variables for normal user-facing setup.
- Include attribution for vendored third-party work.
- Make tool success honest and narrow; do not report broad task success from a low-level event.
