# Zinc 0.2.0

- Native binding images replace declaration replay. Vars, closures, mutations, aliases and cycles persist without rerunning initializers.
- Publication is success-only. Failed/cancelled work never erases earlier successful working changes.
- Durable roots own instance worlds; queued roots refresh on execution. Parallel children remain isolated. Nonqueued roots atomically claim or finish with AgentBusy, without automatic retries.
- One flat binding catalogue supplies callable definitions and public resource inspection; nested REPL schema metadata is removed.
- External and code world operations share execution/publication. Administrative roots use mutable requests without unused inference profiles. Save intents precede Git ref mutation; reconciliation never replays code.
- World views and prompts show recorded Janet definition forms rather than type inventories. Old images require audited source annotation; saving never depends on source availability.
- Memory views have readable headings, fenced code, formatted JSON, summaries and retrieval-candidate tables; exact request rendering remains available.
- Standard Janet, native docs, entropy-seeded randomness, evaluator-local deadlines and explicit unlimited limits.
- Importable design documentation and shared verified lexical assets with resource attribution.
- Inquiry-v1 coordinates retain agent/caller identity. Observe reattaches without replay; init/join support owned instances.
- RAM journals overlay immutable archived history; child snapshots carry only temporary additions. Call controls alone own parent/kind/persistence metadata.
- Streaming previews retain deltas outside execution checkpoints. Binding metadata loads from images on demand; usage projections derive from the raw report.
- Asset generation has one owner, verifies the source once, and hard-links the generated graph into local assets.
- Package version remains 0.2.0 and schema 1. Preserve incompatible databases, ledgers and source-world repositories and initialize fresh stores; no silent migration. Deploy matching Connector 0.2.0.
