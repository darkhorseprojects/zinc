# Release notes

Both model protocols now stream through unmodified Spork. Typed presentation updates commit through the journal owner;
public reasoning, tool calls, results, and boundary footers remain separate from native replay and internal summaries.
Final-answer identity prevents duplicate settlement output. Cancellation and failure close unfinished presentation.

The single journal retains complete fibers, waits, effects, receipts, worlds, and memory membership. Existing primitives
support both recovery of interrupted instructions and later submissions to a completed child path. Shared-world
publication can still conflict. Dispatched effects without receipts remain unknown and are not retried.

Native checkpoints require their exact runtime source. Archive incompatible history before fresh initialization. No
continuations are migrated, no uncertain actions replayed, and no version or schema number changed.
