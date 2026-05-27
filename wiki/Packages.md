# Packages

A Zinc package is a directory with `zinc.pkg.yaml`.

```yaml
name: browser-repair
version: 0.1.0
exports:
  graphs:
    repair: graphs/repair.circuitry.yaml
  prompts:
    dom-debug: prompts/dom-debug.md
  assets:
    sample: assets/sample.png
```

Install locally or globally:

```bash
zn pkg add ./package
zn pkg add --global github:user/repo/path/to/package
zn pkg add github:user/repo#v1.0.0
zn pkg add https://github.com/user/repo.git#<commit>
```

The recorded source is stored with the installed package. `zn pkg update <name>` reinstalls from that recorded source. If the source includes `#tag` or `#commit`, updates stay pinned there.

Top-level `zn update` updates all installed packages before updating Zinc itself.
