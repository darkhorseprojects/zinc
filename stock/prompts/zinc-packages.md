# Zinc packages

Packages add explicit model context and tools to a Zinc loop graph.

A package may ship prompts, files, graphs, scripts, and external tools. Installing a local package can patch `.zinc/graphs/zinc-loop.circuitry.yaml` and generate package resources in `.zinc/generated/packages.circuitry.yaml`.

Install patch shape:

```yaml
install:
  model:
    input:
      - prompt:guide
    tools:
      - package_tool
```

Prompts are not loaded by name alone. Tools are not callable by name alone. They must be present in the graph model resource.

Package layout convention:

- `.zinc/packages/<name>`: installed package code and assets
- `.zinc/config/packages/<name>.yaml`: user/project package config
- `.zinc/runtime/packages/<name>`: package working runtime
- `.zinc/generated`: Zinc-generated wiring

Tool handlers are `process`, `http`, or `mcp`. Use `run_graph` for graph assets.

Prefer config files over environment variables for normal user-facing package setup.
