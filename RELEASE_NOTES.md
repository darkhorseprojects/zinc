# Release notes

## Single-journal rewrite

All runtime source has been replaced. Complete managed Janet machines checkpoint fibers, locals, shared references and
waits. A single append-only journal retains admissions, checkpoints, dispatches, receipts, worlds, explicit memory views
and output. Queue eligibility and heads are derived; no dependency column, queue table, reference table or cache table
is maintained.

The recursive agent loop uses the same runtime as scripts. Model tools await actual script results. Child paths can be
continued explicitly, while local tasks settle with their request. Lost processes resume saved continuations; ambiguous
dispatched effects receive unknown outcomes without replay. Worlds compare revisions and retain conflicting candidates.
Rewind creates a new revision rather than cancelling unrelated work or undoing effects.

Chronological memory uses immutable pages and lazy binary summaries. Semantic memory retains Cygnet/FTS/fuzzy retrieval
and reranking against the same explicit membership. Model protocol adapters retain native replay for Chat Completions
and Responses. Connector consumes generic application manifests and output, not Zinc's internal state model.

This is a fresh-store and fresh-transport-state cutover. Archive old state and stop old work first. Legacy continuations
are not converted. Existing author handles may be retained for the same author. Release and schema numbers are unchanged.
