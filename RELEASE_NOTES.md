# Zinc 0.2.0

- Platform runtime archives expose `zinc.md` and `models.ini` at the package
  root, with only runtime dependencies in `lib`; Jpm build trees and state are
  excluded.
- `jpm run package` builds the same layout locally and on all six CI targets.

- World source follows top-level definitions, redefinitions and nil removal.
- Parallel tool calls fork a shared source/history snapshot into independent
  branches.
- Every model round records its exact request, current source and memory
  windows.
- Trusted `views` and `render` exports inspect saved prompts without
  recomputation.
- Rerank scores remain inspectable without rendering model bookkeeping.
- REPL profiles explicitly select functions and schema-approved settings. Named
  filesystem roots, HTTP bases and fixed commands execute through data-only host calls.
- Native REPL authority is always disabled; named grants and selected settings
  appear in prompts. Saved calls cannot acquire newly added grants.
- Zinc owns provider model allowlists and `token-env` credential references;
  Connector model transports and boolean `repl` configuration are removed.
- Tool failures retain printed output and structured details, including parallel
  admission failures; matching PA protocol-3 diagnostics preserve boundary stacks.
- Committed compaction displays source membership, not generated summary text.
- Stopwords, resource provenance and the Cygnet builder install with package
  sources.
- Tests and embedded CI fixtures are removed; six-platform build CI remains.

Database schema version is 1. Preserve incompatible stores and provision a fresh
path; there is no migration or compatibility execution path.
