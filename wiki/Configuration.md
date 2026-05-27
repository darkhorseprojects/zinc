# Configuration

Config files are read in this order:

```text
.zinc/config.yaml
~/.config/zinc/config.yaml
built-in defaults
```

The project file overrides the user file, and both override defaults.

Common keys:

```yaml
paths:
  graph: ~/.local/share/zinc/graphs/zinc-loop.circuitry.yaml
  compiled_plan: ~/.local/share/zinc/compiled/plan.json
  compaction_graph: ~/.local/share/zinc/graphs/zinc-compaction.circuitry.yaml
provider:
  base_url: http://127.0.0.1:30000/v1
  authorization: Bearer zinc
runtime:
  max_retries: 5
  compaction_threshold_percent: 70
```

Inspect a value:

```bash
zn config get provider.base_url
```
