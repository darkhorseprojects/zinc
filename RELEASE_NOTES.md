# Whole messages and interrupted history

Model calls use bounded complete JSON responses, not SSE fragment persistence. Existing event IDs and histories are retained. Usage reports survive response-validation failures.

Automatic history attachment includes the latest committed failed/interrupted work. Abort receipts belong to branch history; cancellation is cooperative, not rollback. Reattachment emits committed messages before returning saved outcomes.

Redundant context caches, memory handle wrappers and fragment machinery are removed. Source formatting now distinguishes validation, admission, execution and outcome boundaries.

# Development baseline

Zinc owns self, independent task execution, source-based world branches, user/agent profiles and one optional commit capability.

Resident services, Unix sockets, REPL/ledger relays, fake agent delegation, Git imports and public invoke/eval selectors are removed. Built-in functions and ordinary supplied library proxies are called directly.

Prompts discover the provided libraries' public callable bindings/docstrings without knowing Connector. Private configuration stays in the trusted runtime.

Separate executions have separate heaps. Entry source is inherited; arbitrary live heaps and filesystem writes are not cloned or merged. Native access still requires appropriate OS confinement.

Tasks can append outcomes after their PA observer dies. Deadlines, leases, generation fencing and manual effect recovery remain. Preserve old development stores and provision a fresh source-branch schema; no migrations are provided.
