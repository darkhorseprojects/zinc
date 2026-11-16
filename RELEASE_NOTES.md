# Release notes

Zinc exports `invoke(input, config, imports)` and owns its configuration,
navigation, operations and presentation. It no longer implements a shared
application discovery/profile contract or persists host routing context.
Imported functions are live invocation attachments; unfinished work resumes only
through an explicitly authorized reattachment.

User and agent VM configuration are separate. Managed tasks inherit their role,
and retained closures cannot carry a privileged import into a less-privileged
task. Journal records distinguish ownership from authorship. A metadata record
persists the store identity independently of its path, using the existing
two-table schema and unchanged schema version.

There is no migration, package/schema version bump, or automatic deletion.
Existing histories lacking identity metadata need an explicitly authorized
fresh-history cutover; unfinished machines still require their original runtime.
