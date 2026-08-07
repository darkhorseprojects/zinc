#!/usr/bin/env python3
import concurrent.futures
import json
import sqlite3
from support import Package, success

package = Package()
try:
    entries = []
    for index in range(12):
        entry = f"_writer_{index}.lua"; entries.append(entry)
        (package.package / entry).write_text(f'''
local store=require('./src/store.lua'){{store='store',store_bytes=4096}}
local run=store:begin{{actor='actor-{index}',snapshot=store:snapshot(),request='request-{index}'}}
store:append(run,{{type='response',source='zinc',value='response-{index}'}})
store:close()
return tostring(run)
''', encoding="utf-8")

    def write(entry):
        return int(success(package.run(entry, authority=(entry, "src/store.lua"), timeout=30)).stdout)

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(entries)) as pool:
        runs = list(pool.map(write, entries))
    assert len(set(runs)) == len(entries)
    connection = sqlite3.connect(package.home / ".agents/zinc/store/zinc.sqlite3")
    rows = connection.execute("SELECT idx,run,actor,data FROM slices ORDER BY idx").fetchall()
    connection.close()
    assert len(rows) == 24 and len({row[0] for row in rows}) == 24
    by_run = {}
    for _, run, actor, data in rows:
        by_run.setdefault(run, []).append((actor, json.loads(data)))
    for slices in by_run.values():
        assert len(slices) == 2 and slices[0][0] == slices[1][0]
        suffix = slices[0][0].removeprefix("actor-")
        assert slices[0][1]["value"] == f"request-{suffix}"
        assert slices[1][1]["value"] == f"response-{suffix}"
finally:
    package.close()
print("ok concurrency")
