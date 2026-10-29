# Zinc 0.2.0

- Native binding images replace declaration replay. Vars, closures, mutations, aliases and cycles persist without rerunning initializers.
- Publication is success-only. Failed/cancelled work never erases earlier successful working changes.
- Durable roots own instance worlds; queued roots refresh on execution. Parallel children remain isolated. Nonqueued roots atomically claim or finish with AgentBusy, without automatic retries.
- One flat binding catalogue supplies callable definitions and public resource inspection; nested REPL schema metadata is removed.
- External and code world operations share execution/publication. Save intents precede Git ref mutation; reconciliation never replays code.
- Standard Janet, native docs, entropy-seeded randomness, evaluator-local deadlines and explicit unlimited limits.
- Importable design documentation and shared verified lexical assets with resource attribution.
- Inquiry-v1 coordinates retain agent/caller identity. Observe reattaches without replay; init/join support owned instances.
- Package version remains 0.2.0 and schema 1. Preserve incompatible databases, ledgers and source-world repositories and initialize fresh stores; no silent migration. Deploy matching Connector 0.2.0.
