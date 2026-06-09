# Zinc

Zinc is a local runtime for Circuitry 0.6 action-shapes.

Zinc loads portable Circuitry action-shapes, prepares their inputs, executes them in a governed environment interception loop, records run traces in Limbo, and settles outputs.

## Circuitry 0.6 Format

Circuitry 0.6 is a tiny YAML shape for reusable actions. Core fields:

- `circuitry`
- `name`
- `about`
- `takes`
- `does`
- `gives`

Example (`examples/search-web.circuitry.yaml`):

```yaml
circuitry: "0.6"
name: search-web
about: Search the web, read sources, and return a cited answer.

takes:
  query: text

does: |
  Search for the query.
  Open relevant sources.
  Compare results.
  Return a grounded answer.

gives:
  answer: text
  sources: list
```

## CLI

The Zinc CLI (`zn`) provides a simplified subcommand surface:

```bash
# Run a Circuitry shape
zn run <shape-path> [args]

# Read a file or zinc:// reference
zn read <uri-or-file>

# Inspect a shape, package, run, or reference
zn inspect <uri-or-file>

# Manage packages (install, remove, list, check)
zn pkg <subcommand> [args]

# View active configuration
zn config
```

## Local Layout

A workspace uses a local `.zinc` directory for state:

```text
.zinc/
  packages/     Installed package directories
  state/
    zinc.db     Limbo database containing runs, documents, packages, and policy approvals
  tmp/          Short-lived temporary execution files
```

## Configuration

Zinc configuration uses `config.yaml` located in the workspace `.zinc/` or global path (`~/.zinc/config.yaml`).

```yaml
mode: build     # Command interception mode: inspect, open, build
scope: project  # Access scope: project, home, system
```

## Building

Zinc is written in Zig 0.16.0. Build from source:

```bash
zig build
```

## License

Apache-2.0
