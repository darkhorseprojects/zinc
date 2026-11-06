# Release notes

Model tools execute full Janet scripts with native ev concurrency. Scripts, their root returns and their
independent host effects have separate lifetimes. Output and individual results publish as soon as they
commit; parallel calls never gather sibling outcomes implicitly. Discord shows clojure source blocks and
fenced, source-correlated results.

Restart discovers unfinished execution without replaying original source. Lost VM continuations and
ambiguous effects become explicit uncertainty for model-led inspection and continuation. Evidence-backed
resolution can settle an effect or approve a new attempt under the same identity.

Worlds and configuration remain JSON. Temporary roots and descendants remain RAM-only. The database
layout and version are unchanged. Finish old unfinished workflows under their original installation
before upgrading; replace public task/* grants with self/* and effect/*, and grant ev/* as appropriate.
