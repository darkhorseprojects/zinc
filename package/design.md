# Design

Portable Agents compiles `package/` into an Image and fixes `zinc.md` as its sole entry. Root and member calls exchange bytes and receive opaque embedder-controlled config. Generated Eval Lua receives only explicitly selected entry members and configured external Imports.

`zinc.md` owns deployment composition: authored documents, presets, model routes, Store location, retrieval policy, and limits. Preset Markdown modules return literal tables. Every preset member keeps its callable byte adapter beside the prompt that describes it. Unsafe contains unrestricted PA adapters, safe contains trusted editable wrappers, and no-host has no members.

`src/entry.lua` owns the PA boundary. It validates static composition, strict config, strict call input, trusted actor identity, preset selection, and the static union of preset member names. Direct preset-member calls dispatch through opaque config and reject when unavailable. `src/run.lua` receives typed values and owns only one invocation's messages, event head, model rounds, selected Eval view, parallel tools, and ordered persistence phases.

`src/store.lua` is the sole owner of SQLite schema, event rows, coordinates, actor checks, transactions, and queries. It appends each local event phase in one short ordered transaction. No transaction spans model, HTTP, process, Eval, or imported-Agent work. `src/memory.lua` owns chronological selection, grounding, Cygnet expansion, semantic search, reranking, token fitting, and context serialization. `src/model.lua` owns model HTTP, exact prompt token checks, SSE normalization, tool validation, and reranking. `src/json.lua` owns strict JSON byte decoding and the JSON null sentinel.

A call contains exactly `question`, `parent`, and `memory`. Actor and preset come exclusively from trusted config. Parent chooses branch attachment; memory independently chooses the inclusive actor-owned retrieval boundary. Events are append-only and preserve model order.

Every Eval view contains `document`, `design`, and `zinc`, plus exactly the selected preset's members. The entry contains the trusted union required by PA's static member-selection contract, but unavailable direct members reject. Generated code receives `self` and `input` as prebound locals, loads only caller Imports, and returns one string. Independent tool calls execute concurrently and persist in model order.

Safe writes are confined to `workspace/`. Store, Cygnet, package source, models, and runtime modules remain outside safe filesystem authority. Unsafe deliberately permits request-selected PA authority. The embedder independently owns the Import authority graph.
