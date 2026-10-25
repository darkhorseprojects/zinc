# Zinc 0.2.0

- Standard Janet processes and fibers replace PA spawn/await handles; imports use `portable-agents/protocol`.
- Durable completion remains in SQLite; temporary outcomes remain in their owning call.
- Ordinary stdout carries inquiry-v1 NDJSON presentation; stderr carries logs.
- Remarkable supplies CommonMark parsing and the module's structured `document` value.
- The trusted `instructions` entry returns composed instructions without shadowing document data.
- Runtime archives contain only required Janet sources and native libraries, not PA's worker or host module.
- Package version is 0.2.0; database and presentation schemas are 1. No migration or compatibility path is included.
