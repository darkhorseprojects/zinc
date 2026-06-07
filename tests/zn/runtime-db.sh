#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ZN="$ROOT/zig-out/bin/zn"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"
zig build >/dev/null

cd "$WORK"
mkdir .zinc

path=$($ZN db path 2>&1)
[ "$path" = ".zinc/runtime/zinc.db" ]

tables=$($ZN db tables 2>&1)
printf '%s' "$tables" | grep -q $'sessions\ttable'
printf '%s' "$tables" | grep -q $'events\ttable'
printf '%s' "$tables" | grep -q $'recent_events\tview'

schema=$($ZN db schema 2>&1)
printf '%s' "$schema" | grep -qi 'create table sessions'
printf '%s' "$schema" | grep -qi 'create table events'

query=$($ZN db query 'select count(*) as n from sessions' 2>&1)
printf '%s' "$query" | grep -q $'n\n0'

$ZN clean --local --yes runtime >/dev/null
[ ! -e .zinc/runtime ]
