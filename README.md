# Zinc

Zinc runs chat models with persistent history and Lua tools. It is a
[Portable Agents](https://github.com/darkhorseprojects/portable-agents) package;
[Agent Connector](https://github.com/darkhorseprojects/agent-connector) connects it to Discord.
Chat and reranking can use llama.cpp or OpenRouter independently.

## Install

Install `agent` with protocol 2, `agc` with YAML 2 support, and the matching Lua 5.5 shared library.
Zinc archives do not include these programs, model weights, or a model server.

Extract the archive for your platform, then run:

```sh
./install.sh /path/to/zinc
```

On Windows:

```powershell
.\install.ps1 -Destination C:\Agents\Zinc
```

Without a destination, the installer uses `${XDG_DATA_HOME:-$HOME/.local/share}/zinc` on Linux,
`~/Library/Application Support/Zinc` on macOS, or `%LOCALAPPDATA%\Zinc` on Windows.

Reinstalling preserves `ac.yaml`, `models.ini`, and `state/`. Existing format-3 Stores do not need resetting.
For older config or Store formats, follow [release notes](RELEASE_NOTES.md) before upgrading.

## Start locally

From the installed directory, start the Prism llama.cpp build specified in `models.lock`:

```sh
llama-server --models-preset models.ini --port 8000
```

In `ac.yaml`, replace the empty member route with your Discord user ID:

```yaml
members:
  "123456789012345678": zinc
```

In another terminal:

```sh
agc check /path/to/zinc
agc connect /path/to/zinc
agc run /path/to/zinc
```

`connect` stores your bot credential; skip it if this directory is already connected.
Message the bot in a DM, mention it in a server, or use:

```text
/agent zinc prompt: draw a heart thinking: medium input_parent: 0 input_through: 0
```

Reasoning appears as quotes, tool calls as Lua blocks, and tool results as text blocks.
The shipped configuration grants no filesystem or HTTP tools. Enable only the
[tool permissions](https://github.com/darkhorseprojects/zinc/wiki/Configuration#tool-permissions) you need.

## Configure

Edit `policies.zinc.config` in `ac.yaml`. `chat` and `rerank` select independent `provider:id` references.
`thinking` selects an explicit effort (`medium` by default, `none` to disable). `run.tokens: 0` and
`limits.chat.tokens: 0` use model-derived budgets; positive settings remain caps.
See [Models](https://github.com/darkhorseprojects/zinc/wiki/Models) for hosted setup and troubleshooting.

JSON requests accept `text`, optional `images`, and optional `parent`/`through` history coordinates:

```json
{ "text": "Start a new topic", "parent": 0, "through": 0 }
```

See [Configuration](https://github.com/darkhorseprojects/zinc/wiki/Configuration) for settings and defaults,
and [History and retrieval](https://github.com/darkhorseprojects/zinc/wiki/History-and-Retrieval) for continuation examples.

## Build from source

```sh
python3 tools/format_fences.py
lx --lua-version 5.5 fmt --backend stylua --path package/src
CFLAGS=-DSQLITE_ENABLE_FTS5 lx --lua-version 5.5 build --only-deps
agent check package zinc
```

A runnable package needs lunajson, the Lua 5.5 SQLite binding under `package/native/`, and Cygnet format-4 data.
SQLite must support FTS5 and trigram tokenization. See [Development](https://github.com/darkhorseprojects/zinc/wiki/Development)
for dependency layout.

License: [AGPL-3.0-only](LICENSE).
