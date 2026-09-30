# Design

Portable Agents executes trusted Lua/Markdown and transports opaque bytes. Zinc owns JSON requests, config, model protocols, state, retrieval, and tool execution. Connector owns Discord routing, credentials, controls, and rendering. Zinc is effectful: explicit config, stored state, and external replies determine its behavior; it is not a pure function.

A root call creates an actor-owned run and durable branch. Runs own the reported-token budget. Branches own attachment, inclusive history boundary, preset, temporary lifetime, and terminal response. Events own kind and text, not token counts. Failed durable branches remain auditable and eligible for actor-owned continuation. Automatic attachment is selected in the branch-creation transaction.

Quota counts provider-reported total tokens from completed chat and rerank requests. It is checked before each later request; final and already-running concurrent requests can overshoot. Source/result bytes have separate ceilings. Nested calls resolve the shared run through their caller event, cannot replace actor identity, and create temporary branches. Destruction removes an authorized temporary branch and its descendants.

Preset Markdown supplies instructions; preset Lua supplies signatures, adapters, and implementations. Configured roots, HTTP actions, and the search executable come from private config, not ambient home state. Nested presets can retain or reduce host authority. PA owns Imports separately; opaque config cannot create or replace an Import grant.

`src/entry.lua` owns the JSON boundary, config validation, and named metadata members. `src/run.lua` owns the model loop, branch lifecycle, Eval batches, and structured emissions. `src/store.lua` owns format-3 state, coordinates, quota, and short transactions. `src/memory.lua` owns actor-visible history, trigram spelling candidates, Cygnet expansion, and reranking. `src/model.lua` owns provider catalogs, exact reference resolution, HTTP/SSE parsing, and usage normalization.

No Store transaction spans model, host, Eval, process, or Import work. Completed JSON results carry coordinates and usage; JSON events identify branch and channel. Presentation does not belong to Zinc. Ordinary source failures become tool results; call-level failures propagate with diagnostics rather than inventing results.
