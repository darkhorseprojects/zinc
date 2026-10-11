# Unreleased — current Janet stack

- PA protocol 6; immutable composition and one durable jobs path for recursion, capabilities and Imports.
- SQLite format 9, persistent working/accepted worlds, fenced intent/outcomes, cancellation tombstones and bounded slot release.
- Original-source summary checkpoints, scoped FTS/trigram/Cygnet retrieval, UTF-8 handles and validated Git activation/rollback.
- Native JSON/SSE parity, conservative unreported usage, hidden reasoning policy and final-round explanation without tools.
- Connector configuration 3 example, isolated regression/crash/security fixtures and reproducible fixture benchmarks.
- Structural size gate: agent 576/724 lines, store 468/586. Preserve old databases and select a fresh format-9 path.

The notes below describe the preceding development snapshot, not the current protocol.

# Zinc v0.3.0

Zinc now runs on Janet and Portable Agents protocol 4. This is a fresh application, not a compatibility release.

## Requirements and installation

Use Janet 1.42.1, Git, SQLite with FTS5/trigram support, libcurl and the revision-pinned dependencies in `project.janet`. Supply the dependency tree as PA's named `library` dependency. Invoke `install` to validate and publish source before making conversational calls.

Use a fresh application database and a coordinated Git world namespace. Old Lua SQLite stores and nested configuration are unsupported; there are no migrations or compatibility adapters. Preserve old state offline if needed. Do not delete a live database while retaining its published refs and expect a fresh installation.

## Interface

- `call` remains conversational inference; it is not an eval or maintenance endpoint.
- `install`, `invoke`, `resume`, `worker`, `events`, `acknowledge`, `abort`, `pending`, `models` and `describe` are separate entries.
- Configuration is flat private JSON with required actor/store/repo/state identity and absolute application paths.
- Tool programs are Janet. Learned capability descriptors live in revision-pinned `src/functions.janet`.
- Lua sources, Lux configuration, old installers, Lua tooling and old CI were removed.
- Model presets and asset pins remain. The old `ac.yaml` was not changed and is not configured for this interface; Connector integration is outside this update.

## Durability

One application SQLite database stores immutable originals, images, model stream bytes, task attempts/outcomes, summary provenance, budgets and publication receipts. Model, tool, recursive and background work use one persisted task mechanism with leases and completion fencing.

Safe/keyed work can resume from committed checkpoints. Irreversible effects are not automatically replayed. Source-defined reconciliation and validated publication receipts can establish outcomes. Cancellation does not roll back effects or promise immediate termination.

Git worlds use source-defined validation and compare-and-swap refs. Prepared publications are recoverable; unvalidated candidates cannot be promoted. Existing runs execute their admitted revision while new calls use accepted source. The default validator checks loadability and required exports, not behavioral correctness.

## Memory and models

Chronological memory uses a summary DAG with strict-shrinking compaction and lossless access to retained originals. Semantic retrieval preserves the original query, uses Cygnet graph expansion and FTS/spelling candidates, and reranks scoped excerpts. A compatible format-4 index must be provisioned separately; raw upstream Cygnet data is incompatible.

Context sizing uses UTF-8 quarter-byte reference units. Model budgets reserve estimated units across shared work and retain provider-reported usage separately. They are not exact tokenizer or billing guarantees. Unknown usage remains conservatively accounted.

## Validation and limits

Real PA workflows exercised installation, independent workers, revision-pinned calls, learned functions, map/reduce, audit replay, cursors, source reconciliation after a durable effect, invalid-source rejection and restore. SQLite integrity/foreign-key checks passed. No tests were added.

No model endpoint was available. Live inference, provider/SSE behavior, image handling, recursive inference and inference-quality/performance benchmarks remain unvalidated.

Arbitrary Janet is not sandboxed, including under the `empty` preset. The invoker remains responsible for OS confinement, identity, credentials, hard resource limits and process lifetime. Backups must retain the SQLite database/WAL and Git refs/objects together.
