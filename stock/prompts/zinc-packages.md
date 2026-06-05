# Zinc packages

Packages add explicit model context and tools to a Zinc loop graph.

A package may ship prompts, files, graphs, scripts, and external tools. Installing a package patches the selected model resource with declared inputs and tools:

```yaml
install:
  model:
    input:
      - prompt:guide
    tools:
      - package_tool
```

Prompts are not loaded by name alone. Tools are not callable by name alone. They must be present in the graph model resource.

Tool handlers are `process`, `http`, or `mcp`. Use `run_graph` for graph assets.
