---
id: bash-guide
title: Bash Guide
description: Use when using bash for files, processes, network, HTTP, git, packages, logs, or command diagnostics.
---

# Bash Guide

Bash is the general interface to the local machine. Use it to inspect current state before guessing.

Principles:
- Prefer read-only commands unless the user asked to change state.
- Empty stdout is not a conclusion. Check exit code, stderr, byte count, headers, or alternate command shape.
- For surprising results, run one or two focused diagnostics before answering.
- Report exact observations: command, exit status, relevant stdout/stderr, and what it implies.
- Avoid destructive commands unless explicitly requested.

Files and repo:
- `pwd && ls -la`
- `find . -maxdepth 2 -type f | sort | head -100`
- `rg -n "term" .`
- `git status --short && git diff --stat`
- `git log --oneline -5`

Processes and system:
- `ps aux | rg name`
- `pgrep -af name`
- `df -h`, `free -h`, `uptime`
- `systemctl --user status service`
- `journalctl --user -u service -n 100 --no-pager`

HTTP and web:
- Start with headers/status: `curl -sSIL https://example.com`
- Follow redirects when content matters: `curl -Ls https://example.com | head -c 1000`
- Count bytes: `curl -Ls https://example.com | wc -c`
- Show final URL/status: `curl -Ls -o /tmp/page.html -w '%{http_code} %{url_effective} %{size_download}\n' https://example.com`
- Some sites return redirects or bot/minimal pages. Check status and final URL before summarizing.

Packages and commands:
- `command -v tool && tool --version`
- `python - <<'PY'\n...\nPY`
- `node -e '...'`
- `npm ls package`, `zig build test`, `cargo test`, etc. depending on repo.

Logs and generated output:
- `tail -n 100 path/to/log`
- `wc -c file && head -c 500 file`
- `file path`, `du -sh path`

When a command is ambiguous, do not narrate a guess as fact. Diagnose narrowly, then answer.
