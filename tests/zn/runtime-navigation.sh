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
$ZN db tables >/dev/null 2>&1
python - <<'PY'
import sqlite3
con=sqlite3.connect('.zinc/state/zinc.db')
con.execute("insert into sessions(id,cwd,created_at,updated_at,current_branch,status) values ('stest','.','2026-01-01T00:00:00.000Z','2026-01-01T00:00:01.000Z','main','active')")
con.execute("insert into events(id,session_id,parent_id,branch,type,source_kind,source_name,time,summary,payload_json) values ('e1','stest',null,'main','session.message.user','core','zinc','2026-01-01T00:00:01.000Z','hello','{}')")
con.execute("insert into branch_heads(session_id,branch,head_event_id,updated_at) values ('stest','main','e1','2026-01-01T00:00:01.000Z')")
con.execute("insert into logs(session_id,event_id,time,level,component,message,fields_json) values ('stest','e1','2026-01-01T00:00:02.000Z','info','test','hello log','{}')")
con.execute("insert into meta(key,value_json) values ('last_session_id','\"stest\"')")
con.commit()
PY

sessions=$($ZN session list 2>&1)
printf '%s' "$sessions" | grep -q stest

events=$($ZN event tail 2>&1)
printf '%s' "$events" | grep -q session.message.user

logs=$($ZN logs tail 2>&1)
printf '%s' "$logs" | grep -q 'hello log'

$ZN session branch --at e1 --name retry >/tmp/zinc-branch.out 2>&1
grep -q 'created branch retry' /tmp/zinc-branch.out
$ZN session checkout retry >/tmp/zinc-checkout.out 2>&1
grep -q 'checked out branch retry' /tmp/zinc-checkout.out

tree=$($ZN session tree 2>&1)
printf '%s' "$tree" | grep -q retry
