# Release notes

The isolated evaluator is vm.janet. PA framing, bidirectional correlation and event envelopes belong to main.janet, not
the execution engine. Flat call-envelope imports remain documentation; local selections and current resource grants
govern execution. External capability dispatch no longer sends Zinc operation references.

Admissions retain authenticated authors; internally authored tasks use the agent's durable configured handle. Store
identity, deployment revisions, locations and work references remain separate. Peer interfaces expose only self, status
and wait. Owner/local interfaces retain memory, queues, cancellation, configuration and recovery.

Model tools execute full Janet scripts with native ev concurrency. Scripts, their root returns and their independent
host effects have separate lifetimes. Output and individual results publish as soon as they commit; parallel calls never
gather sibling outcomes implicitly. Discord shows clojure source blocks and fenced, source-correlated results.

Restart discovers unfinished execution without replaying original source. Lost VM continuations and ambiguous effects
become explicit uncertainty for model-led inspection and continuation. Evidence-backed resolution can settle an effect
or approve a new attempt under the same identity.

World metadata and configuration remain JSON; heap environments use native images. Temporary roots and descendants
remain RAM-only. The database layout and version are unchanged. Finish unfinished workflows under their original
installation before upgrading; select local self/_, effect/_ and ev/* grants as appropriate.
