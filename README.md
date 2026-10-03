# Zinc

Zinc is a [Portable Agents](https://github.com/darkhorseprojects/portable-agents) package with actor-scoped durable
history, typo-aware retrieval, configured Lua tools, and temporary nested branches. Chat uses llama.cpp or OpenRouter;
reranking uses llama.cpp. Zinc owns model requests and state. Portable Agents executes it; Agent Connector handles
Discord routing, credentials, and presentation.

## Install

Zinc 0.2 requires Portable Agents protocol 2 and Agent Connector YAML 2. Install `agent`, `agc`, and an
architecture-compatible shared Lua 5.5 runtime independently. Release archives do not include these binaries, a model
server, or weights.

Extract the platform-specific Zinc archive, then run:

```sh
./install.sh /path/to/zinc
```

On Windows:

```powershell
.\install.ps1 -Destination C:\Agents\Zinc
```

Without a destination, installers use `${XDG_DATA_HOME:-$HOME/.local/share}/zinc` on Linux,
`$HOME/Library/Application Support/Zinc` on macOS, or `%LOCALAPPDATA%\Zinc` on Windows.

Reinstalling replaces managed package/data files while preserving `ac.yaml`, `models.ini`, and `state/`. **The installer
does not migrate YAML or erase the Store.** For this breaking update, migrate `ac.yaml` to YAML 2 while preserving
routes, and explicitly replace the old Store with an empty format-3 Store before running. Old formats are rejected, not
upgraded. Stop all users of the database before replacing it; its WAL and SHM files belong to that database too. Retain
an offline copy first if its history is needed.

```sh
agc check /path/to/zinc
agc connect /path/to/zinc
agc run /path/to/zinc
```

`connect` is needed for new Discord credentials; an existing directory-scoped credential can be reused. `run` refreshes
the typed `/agent` command. Empty route maps deny access.

## Requests and config

External input is UTF-8 JSON:

```json
{ "text": "What did we decide?" }
```

Optional `images` contains `{type,data}` MIME/base64 objects. `parent` selects the attachment event; `through` selects
the inclusive history boundary. Omitted parent continues from the actor's latest durable event, selected inside the
Store transaction. Omitted through defaults to that parent. `parent:0` starts fresh; `through:0` disables history
independently. Images are not persisted.

Private UTF-8 JSON config is separate:

```json
{
  "actor": "account:42",
  "preset": "configured",
  "store": "/srv/zinc/state/zinc.db",
  "cygnet": "/srv/zinc/data/cygnet.db",
  "providers": { "llama": { "url": "http://127.0.0.1:8000" } },
  "model": "llama:chat",
  "rerank": "llama:rerank"
}
```

Paths, provider origins, tokens, tool grants, actor, and preset are trusted deployment settings. Defaults cover
`thinking`, `run`, `history`, `search`, and model `limits`. Unknown fields fail. Numeric ceilings can only be reduced;
`search.score` is a finite raw reranker cutoff. The tracked `ac.yaml` expands trusted directory/identity templates and
exposes selected tuning fields as typed Discord options, not a free-form YAML override.

Presets are `configured`, `unrestricted`, and `empty`. Configured tools use explicit `tools.roots`, `tools.actions`, and
an optional absolute `tools.search` executable; no home root is inferred. Unrestricted tools accept request-selected PA
capabilities. Empty grants no host tools. Imports remain a separate embedder grant, including under `empty`.

## Models and usage

Select `provider:id` references, such as `llama:chat` or `openrouter:provider/model`. Unqualified IDs are
not accepted. `/v1/models` supplies discovery metadata; it is not an execution preflight. Providers validate model
availability and capabilities. Discovery uses substring matching; execution sends the exact configured ID without
fuzzy matching or fallback.

Start the pinned local model router with `llama-server --models-preset models.ini --port 8000`. Weights and the Prism
llama.cpp revision are described in `models.lock`. For OpenRouter, run `agc login openrouter`, authorize exact
references in policy `models`, and configure the provider using `${openrouter.url}` and `${openrouter.token}`. These
resolve to a revocable loopback grant, not the account key. Local reranking still needs its server. Catalog discovery
contacts the configured providers; an offline provider fails discovery rather than being silently omitted.

Quota counts provider-reported total tokens for completed chat/rerank requests. It is checked before subsequent requests
and may overshoot on a final or concurrent request. Sources and results have byte limits, not tokenizer accounting.
Missing usage and malformed/incomplete streams fail explicitly. OpenRouter's repeated-finish accounting frames and
`usage:null` are handled without accepting new content after finish.

## Results and events

The terminal JSON contains `text`, `run`, `branch`, `event`, `parent`, `through`, and `usage.total_tokens`. JSON
emissions are branch-tagged `start`, `delta`, `turn`, `tool`, and `tool_result` records. Connector renders completed
root-branch content only; it does not parse Markdown footers or expose reasoning and nested content. Final-only calls
remain valid.

Ordinary tool-source failures become tool results. Call-level Eval failures propagate. PA terminal diagnostics include
bounded source-aware details; Connector retains them privately under an incident ID.

## Development

```sh
python3 tools/format_fences.py
lx --lua-version 5.5 fmt --backend stylua --path package/src
CFLAGS=-DSQLITE_ENABLE_FTS5 lx --lua-version 5.5 build --only-deps
agent check package zinc
```

The source check compiles tracked modules only. A complete runnable package also needs lunajson modules, the
platform-native SQLite binding under `package/native/`, and Cygnet data. CI assembles and loads this package on six
targets; release runs additionally prepare Cygnet data and build archives. SQLite requires FTS5/trigram; Cygnet remains
format 4. No spellfix extension is bundled.

See the [wiki](https://github.com/darkhorseprojects/zinc/wiki) for defaults, retrieval, models, and ownership. License:
[AGPL-3.0-only](LICENSE).
