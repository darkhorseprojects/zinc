# Zinc v0.1.0

First public release of Zinc, a Portable Agents package for conversations with actor-scoped durable history, semantic
retrieval, and controlled tool access. Zinc is a package, not a standalone agent runtime.

## Package capabilities

- Chronological and Cygnet-backed semantic retrieval provide bounded context from stored history.
- Actor ownership isolates histories. Explicit branch coordinates and temporary nested branches support controlled
  investigations.
- The `unsafe`, `safe`, and `no-host` presets define distinct host capabilities. Review package code and grants before
  exposing an agent; `safe` is not a universal security guarantee.
- Independent limits bound model rounds, tool calls, HTTP response bytes, retrieval, accepted tool source, and results.
- Model destinations are trusted package settings rather than caller-controlled overrides.

## Install

Choose the archive for the machine running Portable Agents. Zinc's SQLite module is platform-specific.

| Platform            | Asset                              |
| ------------------- | ---------------------------------- |
| Linux x86-64        | `zinc-v0.1.0-linux-x86_64.tar.gz`  |
| Linux ARM64         | `zinc-v0.1.0-linux-aarch64.tar.gz` |
| macOS Intel         | `zinc-v0.1.0-macos-x86_64.tar.gz`  |
| macOS Apple Silicon | `zinc-v0.1.0-macos-aarch64.tar.gz` |
| Windows x86-64      | `zinc-v0.1.0-windows-x86_64.zip`   |
| Windows ARM64       | `zinc-v0.1.0-windows-aarch64.zip`  |

Extract the archive and run `install.sh` or `install.ps1`. The installer places Zinc in the per-user application-data
directory by default. A custom destination may be supplied. Reinstallation updates managed package and retrieval files
while preserving `ac.yaml`, `models.ini`, and `state/`.

Install Portable Agents, Agent Connector, and Lua 5.5 independently. `agent` and `agc` must be on `PATH`; Lua must be
visible to the operating system's dynamic loader. The native module requests `liblua5.5.so.0` on Linux,
`@rpath/liblua.5.5.dylib` on macOS, and `lua55.dll` on Windows.

The archives contain Zinc's Markdown and Lua modules, locked Lua package dependencies, a platform-native SQLite binding,
the generated Cygnet index, installers, configuration, license, and notices. They contain no Lua runtime, Portable Agents,
Agent Connector, model server, or model weights.

Zinc uses Portable Agents protocol 1, append-mode process streaming, bounded HTTP responses, the Portable Agents package
format, and the Lua 5.5 ABI. Compatibility does not require matching repository commits or release versions.

Configure the model endpoint and obtain the models described in `models.lock`; the defaults expect the Prism llama.cpp
build. After installation, run `agc check` against the Zinc directory. Verify downloads with `SHA256SUMS`. Setup and
configuration are covered in the [README](https://github.com/darkhorseprojects/zinc#install) and
[wiki](https://github.com/darkhorseprojects/zinc/wiki).
