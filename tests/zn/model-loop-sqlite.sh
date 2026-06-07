#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ZN="$ROOT/zig-out/bin/zn"
WORK=$(mktemp -d)
LOG=$(mktemp)
trap 'kill ${MOCK_PID:-0} 2>/dev/null || true; rm -rf "$WORK" "$LOG"' EXIT

cd "$ROOT"
zig build >/dev/null
python /tmp/zinc_mock_openai.py >"$LOG" 2>&1 &
MOCK_PID=$!
sleep 0.2

cd "$WORK"
mkdir -p .zinc
cat > .zinc/config.yaml <<YAML
scope: project
default_model: mock
paths:
  graph: $ROOT/stock/graphs/zinc-loop.circuitry.yaml
  compaction_graph: $ROOT/stock/graphs/zinc-compaction.circuitry.yaml
recovery:
  graph: $ROOT/stock/graphs/zinc-context-recovery.circuitry.yaml
  reach: project
  budget_chars: 12000
models:
  mock:
    model: mock-model
    base_url: http://127.0.0.1:38080/v1
    context_window: 16000
    temperature: 0
YAML

out=$($ZN --fresh 'test sqlite runtime' 2>&1)
printf '%s' "$out" | grep -q 'mock ok'
out2=$($ZN --continue 'test recovery runtime' 2>&1)
printf '%s' "$out2" | grep -q 'mock ok'
[ -f .zinc/runtime/zinc.db ]
python - <<'PY'
import sqlite3
con=sqlite3.connect('.zinc/runtime/zinc.db')
types=[r[0] for r in con.execute('select type from events order by time')]
assert 'session.started' in types, types
assert 'session.message.user' in types, types
assert 'session.message.assistant' in types, types
assert 'context.recovery.started' in types, types
assert 'context.recovery.finished' in types, types
assert all('jsonl' not in str(row).lower() for row in con.execute('select * from events'))
PY
[ ! -e .zinc/sessions ]
[ ! -e .zinc/logs ]
