# Development

Safe checks:

```bash
zig build
zig build test
circuitry check .zinc/graphs/zinc-loop.circuitry.yaml
circuitry check .zinc/graphs/zinc-context-recovery.circuitry.yaml
circuitry check .zinc/graphs/zinc-compaction.circuitry.yaml
zig-out/bin/zn compile .zinc/graphs/zinc-loop.circuitry.yaml /tmp/zinc-plan.json
zig-out/bin/zn compact --dry-run .zinc/graphs/zinc-compaction.circuitry.yaml
```

Do not run `scripts/install-linux.sh` casually: it writes to `~/.local` and `~/.config/zinc`.

Release checklist:

1. bump `build.zig.zon`
2. run the safe checks
3. update docs/wiki if command contracts changed
4. tag/push after review
