# Release notes

Execution now uses independently committed tasks, checkpoint-driven continuation and read-only observation. The core
schema is events and claims; search remains a derived memory index. Native concurrency and temporary RAM sessions remain
supported.

Executable Markdown, persistent heap batches, PA hosting and shared-folder installation have been removed. Zinc runs
ordinary Janet source from its own installation. Existing image-based databases require fresh initialization; there is
no migration or compatibility layer. Package, protocol and schema version numbers have not been increased.
