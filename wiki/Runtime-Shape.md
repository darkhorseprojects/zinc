# Runtime Shape

Zinc is intentionally narrow.

```text
Circuitry source graph
  -> circuitry parse/check
  -> resolved graph bundle
  -> Zinc loop plan
  -> OpenAI-compatible tool loop
```

Circuitry owns graph YAML, imports, validation, and normalized JSON bundles. Zinc consumes those bundles and does not parse YAML itself.

Zinc owns:

- config and model profile resolution
- graph-to-loop-plan compilation
- semantic session logs
- context recovery and compaction
- built-in coding tools
- package installation and graph lookup
- local llama.cpp process lifecycle

`zn compile` compiles loop entrypoint graphs. Imported fragments are validated by Circuitry and exercised through the entrypoint that imports them.

`zn compact` owns the compaction graph contract. Compaction is not part of loop compilation.
