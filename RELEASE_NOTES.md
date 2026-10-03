# Zinc v0.2.0

## Requirements

- Portable Agents protocol 2 and Lua 5.5
- Agent Connector YAML 2
- SQLite Store format 3

## Migrate configuration

Stop Connector and other users of the Store before upgrading. Back up configuration and state.
The installer preserves `ac.yaml`, `models.ini`, and `state/`; it does not migrate them.

For older Connector YAML:

- Set `version: 2` and preserve member/channel/guild routes.
- Move PA ceilings under policy `limits`.
- Rename `model_access` to `models`.
- Replace free-form `overrides` with authorized `options` paths and a JSON `input` template.

For older Zinc configuration:

| Old setting | Current setting |
| --- | --- |
| `model` | `chat` |
| `models.chat` | `chat` using a `provider:id` reference |
| config `parent` / `memory` | request `parent` / `through` |
| preset `safe` | `configured` |
| preset `unsafe` | `unrestricted` |
| preset `no-host` or `none` | `empty` |

Replace caller option aliases with these paths:

| Old option | Current path |
| --- | --- |
| `model` / `rerank` | `config.chat` / `config.rerank` |
| `thinking` | `config.thinking` |
| `tokens` / `rounds` / `tool_bytes` | `config.run.tokens` / `config.run.rounds` / `config.run.tool_bytes` |
| `history_records` / `history_bytes` | `config.history.records` / `config.history.bytes` |
| `depth` / `terms` / `candidates` / `search_bytes` / `score` | `config.search.depth` / `config.search.terms` / `config.search.candidates` / `config.search.bytes` / `config.search.score` |
| `parent` / `through` | `input.parent` / `input.through` |

Remove config `version` and translate older retrieval settings into `history` and `search`;
see [Configuration](https://github.com/darkhorseprojects/zinc/wiki/Configuration).
Set actor, Store/Cygnet paths, providers, and tool grants explicitly.

`chat` and `rerank` select independent references. Put every hosted reference in policy `models`.
For example, an enabled caller control uses `options: [config.chat, config.run.tokens, input.parent]`.
Use the shipped `ac.yaml` as the full YAML-2 example; old names are not accepted.

## Store compatibility

Keep an existing format-3 Store. Chat/option renames do not change its format.

Older Store formats cannot be opened by Zinc 0.2. Retain an offline copy if you need their history,
then replace the old database and its WAL/SHM companions together. A missing database initializes
as format 3 on the next request.

After migrating, run:

```sh
agc check /path/to/zinc
```

This validates package loading and controls, not model availability. Verify configured providers
before starting Connector.
