# Design

Portable Agents compiles `package/` with `zinc.md` as its sole entry. Root and imported-Agent calls exchange bytes. Eval capabilities exchange native Lua values through isolated Portable Agents states.

A top-level call creates one run and one durable branch. Runs own actor identity and tool-token budget. Branches own attachment, memory boundary, preset, lifetime, and the successful terminal result. Incomplete durable branches are excluded from continuation and retrieval. Events own kind, text, and tool token count. Nested Zinc calls create temporary branches in the same run. Explicit destruction removes a temporary branch and its descendants.

Quota counts exact chat-tokenizer tokens in accepted Lua sources and their complete results. Source admission is checked before Eval. Accepted results are always stored. Reasoning and regular responses are not charged. Every nested branch resolves the shared run through its caller event.

Preset Markdown supplies operational instructions. Preset Lua supplies resolved whitelists, exact Lua signatures, trusted adapters, and implementations. The generated system prompt contains only the selected preset, its configured names, its Lua capability table, documents from granted `require()` Imports, and initial quota. PA owns the Import graph; opaque config cannot add one.

`src/entry.lua` owns strict nested config overlays and external call bytes. `src/run.lua` owns one model loop, branch creation, Eval batches, and quota reporting. `src/store.lua` owns schema, coordinates, quota, and transactions. `src/memory.lua` owns retrieval. `src/model.lua` owns model HTTP and normalization.
