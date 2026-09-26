# Zinc v0.1.0

First public release of Zinc, a
[Portable Agents](https://github.com/darkhorseprojects/portable-agents) package
for conversations with actor-scoped durable history and controlled tool access.
Zinc is a package, **not a standalone executable**: use it with a matching
Portable Agents `agent` runtime, directly or through Agent Connector.

## Package capabilities

- Chronological and Cygnet-backed semantic retrieval provide bounded context
  from stored history. Actor ownership isolates histories; explicit branch
  coordinates and temporary nested branches support controlled investigations.
- The `unsafe`, `safe`, and `no-host` presets define distinct host capabilities.
  Review the trusted package code and grants before exposing an agent; the
  `safe` preset is not a universal security guarantee.
- Run quotas meter accepted tool source and results. Independent limits bound
  model rounds, tool calls, HTTP response bytes, and retrieval. Configured model
  destinations are trusted package settings rather than caller-controlled
  overrides.
- The release package contains Markdown/Lua modules, locked Lua dependencies, a
  platform-specific native SQLite binding, the generated Cygnet retrieval index,
  `ac.yaml`, model configuration, license, and third-party notices. Its entry is
  `package/zinc.md` (`zinc`).

## Downloads

Choose the archive for the **machine running Portable Agents**; native SQLite
makes these packages platform-specific.

| Platform            | Asset                              |
| ------------------- | ---------------------------------- |
| Linux x86-64        | `zinc-v0.1.0-linux-x86_64.tar.gz`  |
| Linux ARM64         | `zinc-v0.1.0-linux-aarch64.tar.gz` |
| macOS Intel         | `zinc-v0.1.0-macos-x86_64.tar.gz`  |
| macOS Apple Silicon | `zinc-v0.1.0-macos-aarch64.tar.gz` |
| Windows x86-64      | `zinc-v0.1.0-windows-x86_64.zip`   |
| Windows ARM64       | `zinc-v0.1.0-windows-aarch64.zip`  |

A compatible **dynamic Lua 5.5** runtime and Portable Agents `v0.1.0` are
required for the native module. Model server, weights, and the `agent`
executable are **not** included. Configure a compatible model endpoint and
obtain the models described in `models.lock`; the default configuration expects
the Prism llama.cpp build. Run `agent check package zinc` against the extracted
Zinc directory before use. Verify archive hashes with `SHA256SUMS`. Setup and
configuration are covered in the
[README](https://github.com/darkhorseprojects/zinc#use-it) and
[wiki](https://github.com/darkhorseprojects/zinc/wiki).
