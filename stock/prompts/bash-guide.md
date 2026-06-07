---
id: bash-guide
title: Bash Guide
description: Use when using bash for files, processes, network, HTTP, git, packages, logs, or command diagnostics.
---

# Bash Guide

Bash is the general interface to the local machine. Use it to inspect current state before guessing.

## Principles

- Prefer read-only commands unless the user asked to change state.
- Empty stdout is not a conclusion. Check exit code, stderr, byte count, headers, or alternate command shape.
- For surprising results, run one or two focused diagnostics before answering.
- Report exact observations: command, exit status, relevant stdout/stderr, and what it implies.
- Avoid write/edit command heads unless explicitly requested.
- Do not use shell to hide messy behavior that should be a package, graph, or explicit tool.

## Files and repo

Useful first checks:

```bash
pwd && ls -la
find . -maxdepth 2 -type f | sort | head -100
rg -n "term" .
git status --short && git diff --stat
git log --oneline -5
```

Use `read` for normal file inspection when available. Use bash for structure, search, status, and commands.

## Zinc project layout

When working in a Zinc project, know the local layout:

```text
.zinc/graphs/                         project graphs
.zinc/generated/                      Zinc-written wiring
.zinc/packages/<name>/                installed package code and assets
.zinc/config/packages/<name>.yaml     user/project package config
.zinc/runtime/packages/<name>/        package working runtime
.zinc/runtime/zinc.db                 sessions, events, logs, branches
.zinc/tmp/                            short-lived temporary captures
```

Do not casually edit generated files. Change package installs or source manifests and let Zinc regenerate wiring. The SQLite database is the canonical runtime; `.zinc/tmp` is only for short-lived captures such as oversized shell output.

## Processes and system

```bash
ps aux | rg name
pgrep -af name
df -h
free -h
uptime
systemctl --user status service
journalctl --user -u service -n 100 --no-pager
```

For storage cleanup, inspect before deleting:

```bash
du -h -d 1 ~/.cache | sort -h | tail
du -h -d 1 . | sort -h | tail
```

Delete only obvious temporary files unless the user approves broader cleanup.

## HTTP and web

Start with headers/status:

```bash
curl -sSIL https://example.com
```

Follow redirects when content matters:

```bash
curl -Ls https://example.com | head -c 1000
```

Count bytes:

```bash
curl -Ls https://example.com | wc -c
```

Show final URL/status:

```bash
curl -Ls -o /tmp/page.html -w '%{http_code} %{url_effective} %{size_download}\n' https://example.com
```

Some sites return redirects, auth walls, bot pages, or minimal shells. Check status and final URL before summarizing.

## Packages and builds

```bash
command -v tool && tool --version
python - <<'PY'
print('diagnostic')
PY
node -e 'console.log("diagnostic")'
npm ls package
zig build test
cargo test
```

Use the project’s native check command when it exists.

For Zinc package work:

```bash
zn pkg list
zn pkg show <name>
zn pkg exec <name> check
zn check .zinc/graphs/zinc-loop.circuitry.yaml
```

## Logs and generated output

```bash
tail -n 100 path/to/log
wc -c file && head -c 500 file
file path
du -sh path
```

When a command is ambiguous, do not narrate a guess as fact. Diagnose narrowly, then answer.
