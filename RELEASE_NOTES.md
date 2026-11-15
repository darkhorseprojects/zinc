# Release notes

History now contains actual inputs, completed messages and evidence. A two-table store keeps one replaceable running graph
per durable path; checkpoints, private operations and memory nodes no longer consume historical IDs. Recovery reuses known
outcomes and reports dispatched-without-outcome calls as unknown. Temporary invocations stay in RAM.

VM grants and prompt assembly are centralized. Worlds retain binding images and definition source rather than script logs.
Owner inspection supports nearest earlier references; execution remains exact. Binary memory uses event-local nodes and
bounded lazy summaries. Streaming previews and progress are volatile; completed messages remain the durable output units.

Existing stores require an explicit fresh-history cutover. No migration, version bump or automatic deletion is provided.
