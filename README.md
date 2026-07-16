[![Release](https://badgen.net/badge/Release/success/green?icon=github)](https://github.com/darkhorseprojects/zinc/actions/workflows/release.yml)
[![License](https://badgen.net/github/license/darkhorseprojects/zinc?label=License&color=black&icon=github)](LICENSE)

# Zinc

Zinc is a local writing surface backed by immutable packets and completed through Circuitry.

```text
immutable packets ── visual head  ── virtual manuscript
                  └─ context head ── Circuitry turn
```

## Install

Install [Edge.js](https://edgejs.org), unpack Zinc, then:

```sh
edge bin/install.js
zn init
zn up
```

`zn init` creates `config.kdl`, `theme.kdl`, `turn.md`, `definitions/`, the database, packet overflow, logs, and the store registry together. `zn here` creates the same state under `./.zinc`.

## Configuration

```kdl
store "zinc.db"
turn "turn.md"
theme "theme.kdl"
url "localhost"
port 5173
author "anonymous"
completions-url "http://127.0.0.1:30000/v1/responses"
parallel 4
context-tokens 32768
compact-at 80
raw-context-bytes 8192
packet-overflow-bytes 65536
shell "sh"
allowlist { git; rg; find; zn }
```

The theme file is the sole color source. It supplies the background, surface, text, muted, accent, positive, negative, warning, info, and violet colors. Browser CSS derives borders, hover fills, tags, syntax colors, and glass from them.

`author` is an unverified local description, not an account. `agent` and `system` are reserved. Browser requests cannot select an author.

## Threads

Schema v8 stores role-bearing immutable packets behind stable block IDs. The visual head is complete editable history. The context head is a persistent source-backed derivative used for completions. Compaction changes context without removing visible history.

The browser first loads a lightweight block manifest. It fetches visible block payloads in batches, mounts one Lexical editor per loaded block, saves the complete order plus dirty blocks only, and destroys clean offscreen editors. Solid owns rows, dividers, gutters, source tags, forks, and virtualization.

A packet's `role` records the block's conversational purpose. `author` records who most recently produced its bytes. Human edits to an agent block keep its agent role.

One persisted identifier supplies the thread title and tags. Tags are canonicalized to the front and rendered leftmost as `#text` chips. Icons and colors are derived rather than persisted.

Forks are lightweight prefix references. Every branch at a fork point sees every other live member. A fork that returns to its immutable baseline is deleted automatically.

## Editing

Markdown delimiters are real source characters. They collapse at rest, reveal when the caret enters their valid range, and retain the same manuscript typography. Invalid syntax loses only its derived formatting.

Equations retain canonical `$…$` or `$$…$$` source and render through KaTeX. Editing exposes source in the parent Lexical root; Zinc does not create nested editable elements.

TSX previews remain active by default. Their explicit toggle replaces the preview with a normal TSX `CodeNode`; save acknowledgement and Markdown reconciliation do not reverse the toggle.

Reasoning, shell, recall, error, equation, and TSX preview nodes retain their specialized rendering inside each block editor.

## Completions

Dock submission commits dirty thread blocks and new user blocks in one transaction before starting configured `turn.md`. ZincHost derives clean Markdown from canonical packet formats; the browser sends no parallel projection array.

The host supplies thread/context content, structured packet metadata, events, definitions, provider and shell settings, and token measurements as Circuitry inputs. `turn.md` and nested definitions own provider requests and prompting.

Reasoning and response stream transiently. EOF makes output durable. SSE disconnect does not cancel work; explicit cancellation does. Raw model context contains roles and content but no packet IDs, source ranges, or omission comments.

When measured prompt usage reaches `compact-at`, or the hard complete-range byte window cannot fit, the bundled `compact.md` returns ordered keep, summarize, or drop decisions. Zinc maps candidate indexes back to exact packet slices and updates only the context head.

## Cleanup

```sh
zn clean
zn clean --here
zn clean --user
zn clean --thread THREAD_ID
zn clean --packet PACKET_ID
```

Schema v8 is fresh-only. Other schema versions fail and require explicit cleanup.

## Development

```sh
npm install
npm run dev
npm run check
```

TypeScript builds the host, esbuild bundles the Solid browser, Babel compiles Solid and StyleX, and Edge.js runs scripts, tests, Zinc, and its CLI. Production browser output is checked for React emission.

See [SPEC.md](SPEC.md) and the [wiki](https://github.com/darkhorseprojects/zinc/wiki).
