#!/usr/bin/env python3
import json
import os
import sqlite3
from support import Package, success

if os.environ.get("LLAMACPP_REAL") != "1":
    print("skip lfm children (set LLAMACPP_REAL=1)")
    raise SystemExit(0)

package = Package()
try:
    authority = ("src/store.lua", "src/memory.lua", "src/llamacpp.lua", "src/env.lua")
    result = success(package.run(
        "zinc.md",
        input=b"Run a child run via args.run.merge('What is 17 + 25?') to compute the sum, then return the child answer.",
        arguments=("child-actor",),
        authority=authority,
        timeout=300,
        deadline="3m",
    ))
    answer = result.stdout.decode().strip()
    assert "42" in answer, answer

    connection = sqlite3.connect(package.home / ".agents/zinc/store/zinc.sqlite3")
    rows = [(actor, json.loads(data)) for actor, data in connection.execute("SELECT actor,data FROM slices ORDER BY idx")]
    connection.close()
    assert any(data.get("type") == "merge" or data.get("type") == "merged" for _, data in rows)
finally:
    package.close()
print("ok lfm children")
