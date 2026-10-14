import base64
import concurrent.futures
import json
import os
import pathlib
import shutil
import sqlite3
import subprocess
import time

root = pathlib.Path(__file__).resolve().parents[1]
pa = root.parent / "portable-agents"
state = root / "tests" / ".state"
state.mkdir()
world = state / "world"
world.mkdir()
shutil.copyfile(root / "tests" / "world.janet", world / "world.janet")
command = [str(pa / "dist" / ("agent.exe" if os.name == "nt" else "agent")), "spawn", "1048576", "32", "3"]
environment = {**os.environ, "JANET_PATH": str(root.parent)}
config = {"actor": "fixture", "world": "fixture", "store": str(state / "history.db"), "search": False,
          "repl": True, "file": str(world / "world.janet"), "seconds": 2, "parallel": 4, "lease-seconds": 3,
          "capabilities": {"example": {"module": str(root / "tests" / "capability.janet"), "config": {"prefix": "secret:"}}},
          "providers": {"llama": {"url": "http://fixture", "transport": {"module": str(root / "tests" / "provider.janet"), "config": {}}}},
          "chat": "llama:fixture"}


def packet(entry, value, settings):
    return (json.dumps({"version": 1, "program": {"sourceDir": str(root), "entryModule": "zinc.md", "entry": entry,
                         "dependencies": {"library": str(root / "jpm_tree" / "lib")}},
                       "input": base64.b64encode(json.dumps(value).encode() if value is not None else b"").decode(),
                       "config": base64.b64encode(json.dumps(settings).encode()).decode(), "observe": True}) + "\n").encode()


def execute(value, entry="self", settings=None):
    result = subprocess.run(command, input=packet(entry, value, config if settings is None else settings),
                            env=environment, capture_output=True, timeout=15)
    assert result.returncode == 0, result.stderr
    return [json.loads(line) for line in result.stdout.splitlines()][-1]


def code(source, key):
    return execute({"code": source, "request": key})


try:
    for key, source in enumerate(["(double 21)", '(memory/document "descendant")', '(example/echo "value")',
                                  '(import @example) (example/echo "imported")']):
        assert code(source, str(key))["type"] == "result"
    doc = base64.b64decode(execute(None, "document")["output"]).decode()
    assert "example/echo" in doc and "hidden" not in doc and "secret:" not in doc and "commit paths" not in doc
    with concurrent.futures.ThreadPoolExecutor() as pool:
        a = pool.submit(code, '(put state :value 9) (ev/sleep 0.1) (state :value)', "isolated-a")
        b = pool.submit(code, '(ev/sleep 0.2) (state :value)', "isolated-b")
        assert json.loads(base64.b64decode(a.result()["output"]))["text"] == "9"
        assert json.loads(base64.b64decode(b.result()["output"]))["text"] == "42"
        a = pool.submit(code, "(while true)", "timeout")
        b = pool.submit(code, "(ev/sleep 0.2) (double 21)", "sibling")
        assert a.result()["type"] == "error" and b.result()["type"] == "result"
    assert code("(while true)", "timeout")["type"] == "error"
    with sqlite3.connect(state / "history.db") as db:
        assert db.execute("SELECT t.attempt FROM tasks t JOIN runs r ON r.id=t.run WHERE r.request='timeout'").fetchone()[0] == 1
    destination = state / "death"
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
    child.stdin.write(packet("self", {"code": "(ev/sleep 0.4) (double 21)", "request": "death"}, config))
    child.stdin.close()
    assert json.loads(child.stdout.readline())["type"] == "ready"
    until = time.monotonic() + 5
    while time.monotonic() < until:
        with sqlite3.connect(state / "history.db") as db:
            running = db.execute("SELECT count(*) FROM tasks t JOIN runs r ON r.id=t.run WHERE r.request='death' AND t.state='running'").fetchone()[0]
        if running:
            break
        time.sleep(0.02)
    assert running
    child.kill()
    child.wait(timeout=5)
    until = time.monotonic() + 5
    while time.monotonic() < until:
        with sqlite3.connect(state / "history.db") as db:
            outcome = db.execute("SELECT t.state FROM tasks t JOIN runs r ON r.id=t.run WHERE r.request='death'").fetchone()[0]
        if outcome == "done":
            break
        time.sleep(0.02)
    assert outcome == "done"
    child.stdout.close()
    child.stderr.close()
    normal = {**config, "parallel": 1}
    user = {**normal, "inference": False, "commit": True, "agent": normal}
    result = execute({"code": '(await (self {:text "nested"}))', "request": "recursive"}, settings=user)
    assert result["type"] == "result", result
    assert execute({"text": "not authorized"}, settings=user)["type"] == "error"
    subprocess.run(["git", "init", "-q", str(world)], check=True)
    for name, value in [("user.name", "Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false")]:
        subprocess.run(["git", "-C", str(world), "config", name, value], check=True)
    subprocess.run(["git", "-C", str(world), "add", "world.janet"], check=True)
    subprocess.run(["git", "-C", str(world), "commit", "-qm", "Initial"], check=True)
    with (world / "world.janet").open("a") as file:
        file.write("\n(def changed true)\n")
    assert execute({"code": '(commit ["world.janet"] "Denied")', "request": "denied"}, settings=normal)["type"] == "error"
    result = execute({"code": '(commit ["world.janet"] "Allowed")', "request": "allowed"}, settings=user)
    assert result["type"] == "result", result
    assert subprocess.check_output(["git", "-C", str(world), "log", "-1", "--format=%s"]).strip() == b"Allowed"
    assert execute({"request": "allowed", "reason": "already done"}, "abort", user)["type"] == "result"
    with sqlite3.connect(state / "history.db") as db:
        assert db.execute("SELECT count(*) FROM events e JOIN runs r ON r.id=e.run WHERE r.request='allowed' AND e.kind='cancelled'").fetchone()[0] == 0
        assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    print("Zinc isolation, discovery, libraries, nested work, inference, deadlines, observer death and commit permissions passed")
finally:
    shutil.rmtree(state)
