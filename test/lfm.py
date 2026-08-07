#!/usr/bin/env python3
import json
import os
import sqlite3
from support import Package, success

if os.environ.get("LLAMACPP_REAL") != "1":
    print("skip lfm (set LLAMACPP_REAL=1)")
    raise SystemExit(0)

package = Package()
try:
    (package.work / "alpha-dir").mkdir()
    (package.work / "beta.txt").write_text("beta")
    (package.work / "README.md").write_text("# Grounded Workspace\n\nThe verified project marker is GROUNDING-7319.\n")
    authority = ("src/store.lua", "src/memory.lua", "src/llamacpp.lua", "src/env.lua")

    def ask(actor, prompt):
        result = success(package.run("zinc.md", input=prompt.encode(), arguments=(actor,), authority=authority, timeout=300, deadline="3m"))
        return result.stdout.decode().strip()

    listing = ask("model-list", "What entries are in the current directory?")
    reading = ask("model-read", "What verified project marker is written in README.md?")
    working = ask("model-pwd", "What is the current working directory? Use the shell to check.")
    direct = ask("model-direct", "Reply with exactly: zinc-ready")

    connection = sqlite3.connect(package.home / ".agents/zinc/store/zinc.sqlite3")
    rows = [(actor, json.loads(data)) for actor, data in connection.execute("SELECT actor,data FROM slices ORDER BY idx")]
    connection.close()
    evidence = {}
    for actor, fact in (("model-list", "alpha-dir"), ("model-read", "GROUNDING-7319"), ("model-pwd", str(package.work))):
        slices = [data for owner, data in rows if owner == actor]
        tools = [data["value"]["content"] for data in slices if data.get("source") == "tool"]
        calls = [call for data in slices if data.get("source") == "provider" for call in data["value"].get("tool_calls", [])]
        codes = [json.loads(call["function"]["arguments"])["code"] for call in calls]
        evidence[actor] = {"tools": tools, "codes": codes}
        assert tools and any(fact in output for output in tools), (actor, evidence[actor])
        assert codes
    assert "alpha-dir" in listing and "beta.txt" in listing, (listing, evidence["model-list"])
    assert "GROUNDING-7319" in reading, (reading, evidence["model-read"])
    assert str(package.work) in working, (working, evidence["model-pwd"])
    assert direct == "zinc-ready", direct
    assert not any(data.get("source") == "tool" for owner, data in rows if owner == "model-direct")
    report = {"listing": listing, "reading": reading, "working": working, "direct": direct, "evidence": evidence}
    print(json.dumps(report, indent=2))
finally:
    package.close()
print("ok lfm")
