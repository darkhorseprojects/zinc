# Zinc v0.2.0

Coordinated breaking update for PA protocol 2 and Agent Connector YAML 2. These notes describe the source release;
publication is a separate step.

- External requests/results and branch-tagged events are JSON. The Discord-specific Markdown result footer is gone.
- Named `describe` and `models` entry members provide typed control metadata and normalized model discovery. `document`
  and `design` provide package documents.
- Actor identity, Store/Cygnet paths, providers, and tool grants are explicit private config. Generated tools cannot
  replace actor identity.
- Model references are `provider:id`. Unique bare IDs work; ambiguity fails. Known model capabilities constrain
  requests.
- Presets are renamed: `safe` → `configured`, `unsafe` → `unrestricted`, `no-host` → `empty`. Configured host access
  requires explicit grants.
- OpenRouter usage/accounting frames no longer fail just because they repeat the finish reason; JSON null is not usage.
  Malformed streams and provider errors still fail with useful diagnostics.
- Fatal Eval failures propagate instead of being fabricated as ordinary tool results.
- Automatic continuation is selected atomically with branch creation. Parent and history coordinates are separate
  request fields.
- Store format 3 removes obsolete per-event token fields and legacy migrations. It requires a fresh database. Quota uses
  reported model usage.
- Behavior-test fixtures/jobs are removed; builds and artifact checks remain. No spellfix extension or new retrieval
  daemon is introduced.

## Migration

Stop Connector and other Store users. Preserve member/channel/guild routes while replacing YAML 1 with YAML 2. Policy
`models` is the OpenRouter allowlist; `config.model` selects the chat reference. Replace `overrides` with authorized
typed `options`, and supply an explicit JSON `input` template. Move PA ceilings under policy `limits`.

Config has no `version`, `models.chat`, or `retrieval` object: use `model`, `rerank`, `thinking`, `run`, `history`, and
`search`. Move `parent`/`memory` out of config into request `parent`/`through`. Set `store`, `cygnet`, provider origins,
and desired tool grants explicitly. Replace any intermediate `none` preset selection with `empty`; no alias is retained.

The installer preserves old state and YAML; it does not perform this migration or reset. Replace the old Store and its
WAL/SHM companions explicitly, retaining an offline copy if needed. New Store files initialize as format 3.

Install PA, Connector, and the Lua 5.5 shared library independently, then run `agc check` on the installed Zinc
directory. The local llama server is required for local catalog discovery and reranking; hosted chat alone does not
provide reranking. No inference is necessary to check the package/control schema.

Release jobs target Linux x86-64/ARM64, macOS Intel/Apple Silicon, and Windows x86-64/ARM64. Native SQLite must share
PA's Lua ABI. Publish PA 0.2 binaries/SDK, then Connector, then Zinc. Verify published archives against `SHA256SUMS`.
