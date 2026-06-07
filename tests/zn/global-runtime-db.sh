#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ZN="$ROOT/zig-out/bin/zn"
WORK=$(mktemp -d)
HOME_DIR=$(mktemp -d)
trap 'rm -rf "$WORK" "$HOME_DIR"' EXIT

cd "$ROOT"
zig build >/dev/null

cd "$WORK"
HOME="$HOME_DIR" XDG_DATA_HOME="$HOME_DIR/.local/share" XDG_CONFIG_HOME="$HOME_DIR/.config" $ZN db tables >/tmp/zinc-global-tables.txt 2>&1
[ -f "$HOME_DIR/.local/share/zinc/runtime/zinc.db" ]
grep -q $'sessions\ttable' /tmp/zinc-global-tables.txt
HOME="$HOME_DIR" XDG_DATA_HOME="$HOME_DIR/.local/share" XDG_CONFIG_HOME="$HOME_DIR/.config" $ZN clean --global --yes runtime >/dev/null
[ ! -e "$HOME_DIR/.local/share/zinc/runtime" ]
