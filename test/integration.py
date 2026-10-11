import base64
import json
import os
import pathlib
import shutil
import sqlite3
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

source = pathlib.Path(__file__).resolve().parents[1]
pa = source.parent / "portable-agents"
library = source / "jpm_tree/lib"
assert len((source / "src/agent.janet").read_text().splitlines()) <= 579
assert len((source / "src/store.janet").read_text().splitlines()) <= 468
assert len((source / "src/agent.janet").read_text().splitlines()) <= 579
assert len((source / "src/store.janet").read_text().splitlines()) <= 468
assert {path.name for path in (source / "src").glob("*.janet")} == {"agent.janet", "model.janet", "store.janet", "memory.janet", "world.janet", "worker.janet"}
build = source / "dist" / f"regression-{time.time_ns()}"
build.mkdir(parents=True)
for name in ["src", "worlds"]:
    shutil.copytree(source / name, build / name)
for name in ["zinc.md", "project.janet", ".gitignore"]:
    shutil.copyfile(source / name, build / name)
subprocess.run(["git", "init", "-q", str(build)], check=True)
subprocess.run(["git", "-C", str(build), "add", "."], check=True)
subprocess.run(["git", "-C", str(build), "-c", "user.name=Zinc Test", "-c", "user.email=test@localhost", "commit", "-qm", "Regression package"], check=True)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        value = {"data": [{"id": "test"}]} if self.path == "/v1/models" else {"default_generation_settings": {"n_ctx": 8192}, "chat_template_caps": {"supports_tools": True, "supports_tool_calls": True, "supports_parallel_tool_calls": True}}
        self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps(value).encode())

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append(request)
        messages = request["messages"]
        user = next(m["content"] for m in reversed(messages) if m["role"] == "user")
        text = user[0]["text"] if isinstance(user, list) else user
        tools = [m for m in messages if m["role"] == "tool"]
        if "Update the chronological synopsis" in messages[0]["content"]:
            self.server.marker |= "TAIL_MARKER" in text
            content, code = "Original chronology and identifiers retained." + (" TAIL_MARKER" if self.server.marker else ""), None
        elif tools:
            content, code = tools[-1]["content"], None
        elif "tools" not in request or text in ["child investigation", "summary pressure", "unknown usage"]:
            content, code = "42", None
        else:
            content = ""
            code = '(+ 40 2)' if text == "calculate" else '(error "expected tool failure")' if text == "tool error" else '(do (ev/sleep 1) (await (self/world/put "survival" 42 0)) 42)' if text == "detached" else '((await (self {:text "child investigation" :memory_range {:start 0 :end 0} :persist false})) :text)'
        message = {"role": "assistant", "content": content, "reasoning": "思考 private reasoning"}
        if code:
            message["tool_calls"] = [{"id": "tool-1", "type": "function", "function": {"name": "run_janet", "arguments": json.dumps({"code": code})}}]
        result = {"choices": [{"index": 0, "message": message, "finish_reason": "tool_calls" if code else "stop"}], "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20}}
        if text == "unknown usage":
            del result["usage"]
        if self.server.sse:
            delta = {"content": content, "reasoning_content": "思考 private reasoning"}
            if code:
                delta["tool_calls"] = [{"index": 0, **message["tool_calls"][0]}]
            payload = 'data: ' + json.dumps({"choices": [{"index": 0, "delta": delta, "finish_reason": "tool_calls" if code else "stop"}], **({"usage": result["usage"]} if "usage" in result else {})}, ensure_ascii=False) + '\r\n\r\ndata: [DONE]\r\n\r\n'
        else:
            payload = json.dumps(result, ensure_ascii=False)
        self.send_response(200)
        self.end_headers()
        data = payload.encode()
        for start in range(0, len(data), 7):
            self.wfile.write(data[start:start + 7])

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.requests, server.marker, server.sse = [], False, False
threading.Thread(target=server.serve_forever, daemon=True).start()
config = {"actor": "regression", "store": str(build / "state/application.db"), "repo": str(build), "state": str(build / "state"), "world": "empty", "worlds": ["empty", "forked"], "chat": "llama:test", "rerank": "llama:test", "providers": {"llama": {"url": f"http://127.0.0.1:{server.server_port}"}}, "thinking": "none", "search-units": 0, "rounds": 3, "parallel": 1, "lease-seconds": 3, "world-actions": ["merge", "fork", "restore"], "code-actions": ["activate"]}
script = '''
(import "%s/src/pa.janet" :as pa)
(import spork/json :as j)
(def root (os/getenv "ROOT"))
(def deps {"library" (os/getenv "LIBRARY")})
(def program {"sourceDir" root "entryModule" "zinc" "dependencies" deps})
(def worker {"sourceDir" root "entryModule" "src/worker.janet" "dependencies" deps "command" ["bwrap" "--die-with-parent" "--ro-bind" "/" "/" "--proc" "/proc" "--dev" "/dev" "--tmpfs" "/tmp" "--" "janet"]})
(def config (os/getenv "CONFIG"))
(def opts {:member (os/getenv "MEMBER") :limits {"frameBytes" 16777216 "depth" 64 "inFlight" 32 "handles" 4096 "admissionSeconds" 10} :spawn ["janet"] :imports
 [{"name" "worker" "program" worker "config" `{"jailed":true,"source-bytes":65536,"response-bytes":8388608}` "members" ["execute" "validate-image" "validate-package"] "imports" ["ledger"] "spawn" true}
  {"name" "ledger" "program" program "config" config "members" ["receipt"] "imports" ["worker" "ledger"] "spawn" true}]
 :sink (fn [frame] (when (= "emit" (frame "type")) (print "EVENT " (frame "output"))))})
(print "RESULT " (pa/invoke program (os/getenv "INPUT") config opts))
''' % pa

def invoke(member, value, settings=None):
    env = dict(os.environ, JANET_PATH=str(library), ROOT=str(build), LIBRARY=str(library), CONFIG=json.dumps(settings or config), MEMBER=member, INPUT=json.dumps(value))
    result = subprocess.run(["janet", "/dev/stdin"], input=script, text=True, capture_output=True, env=env, timeout=45)
    assert result.returncode == 0, result.stderr + result.stdout
    for line in result.stdout.splitlines():
        if line.startswith("EVENT "):
            event = json.loads(base64.b64decode(line[6:]))
            assert not event.get("reasoning"), event
    return json.loads(next(line[7:] for line in result.stdout.splitlines() if line.startswith("RESULT ")))

started = time.monotonic()
try:
    for streaming in [False, True]:
        server.sse = streaming
        for question, usage in [("calculate", 40), ("recursive", 60), ("tool error", 40), ("unknown usage", 0)]:
            request = {"text": question, "request": f"{streaming}:{question}", "parent": 0, "memory_range": {"start": 0, "end": 0}}
            result = invoke("call", request)
            assert "42" in result["text"] if question != "tool error" else "expected tool failure" in result["text"]
            assert result["usage"]["reported_total"] == usage
            assert result["usage"]["unreported"] == (1 if question == "unknown usage" else 0)
            assert result["usage"]["budget_accounted"] > 0
            assert result == invoke("call", request)
            page = invoke("events", {"run": result["run"], "after": 0})
            assert any(item["type"] == "start" for item in page["events"])
    server.sse = False
    single = dict(config, rounds=1)
    result = invoke("call", {"text": "calculate", "parent": 0, "request": "last-round"}, single)
    assert result["usage"]["reported_total"] == 20
    aborted = invoke("abort", {"request": "pre-cancel", "reason": "caller cancellation"})
    assert aborted["state"] == "cancelled"
    assert aborted == invoke("abort", {"request": "pre-cancel", "reason": "caller cancellation"})
    cancelled_env = dict(os.environ, JANET_PATH=str(library), ROOT=str(build), LIBRARY=str(library), CONFIG=json.dumps(config), MEMBER="call", INPUT=json.dumps({"text": "must not start", "request": "pre-cancel", "parent": 0}))
    cancelled = subprocess.run(["janet", "/dev/stdin"], input=script, text=True, capture_output=True, env=cancelled_env, timeout=45)
    assert cancelled.returncode != 0 and "run cancelled" in cancelled.stderr
    state = invoke("invoke", {"capability": "world/put", "arguments": ["counter", 42, 0], "parent": 0, "request": "state"})
    proposal = json.loads(state["text"])
    accepted = invoke("merge-world", {"image": proposal["image"], "request": "accept"})
    assert json.loads(accepted["text"])["image"] == proposal["image"]
    current = invoke("invoke", {"capability": "world/state", "arguments": ["counter"], "parent": 0, "request": "read"})
    assert json.loads(current["text"]) == {"generation": 1, "value": 42}
    invoke("invoke", {"capability": "world/fork", "arguments": ["forked"], "parent": 0, "request": "fork"})
    other = invoke("invoke", {"capability": "world/state", "arguments": ["counter"], "parent": 0, "request": "fork-read"}, dict(config, world="forked"))
    assert json.loads(other["text"])["value"] == 42
    restored = invoke("restore-world", {"world": "empty", "image": 0, "request": "restore"})
    assert json.loads(restored["text"])["world"] == "empty"
    original_revision = subprocess.check_output(["git", "-C", str(build), "rev-parse", "HEAD"], text=True).strip()
    with (build / "worlds/empty.md").open("a") as document:
        document.write("\n")
    subprocess.run(["git", "-C", str(build), "add", "worlds/empty.md"], check=True)
    subprocess.run(["git", "-C", str(build), "-c", "user.name=Zinc Test", "-c", "user.email=test@localhost", "commit", "-qm", "Validated revision"], check=True)
    next_revision = subprocess.check_output(["git", "-C", str(build), "rev-parse", "HEAD"], text=True).strip()
    activation = invoke("reload", {"revision": next_revision, "request": "code-accept"})
    assert json.loads(activation["text"])["revision"] == next_revision
    rollback = invoke("reload", {"revision": original_revision, "request": "code-rollback"})
    assert json.loads(rollback["text"])["revision"] == original_revision
    memory_actor = dict(config, actor="memory-pressure")
    doc = invoke("invoke", {"capability": "memory/document", "arguments": ["original " * 1500 + "TAIL_MARKER"], "parent": 0, "request": "long-original"}, memory_actor)
    pressure = dict(memory_actor, **{"soft-units": 256, "summary-units": 128, "context-units": 1024})
    summarized = invoke("call", {"text": "summary pressure", "parent": doc["event"], "request": "pressure"}, pressure)
    for _ in range(200):
        if server.marker:
            break
        time.sleep(0.02)
    assert summarized["text"] == "42" and server.marker
    assert summarized == invoke("call", {"text": "summary pressure", "parent": doc["event"], "request": "pressure"}, pressure)
    env = dict(os.environ, JANET_PATH=str(library), ROOT=str(build), LIBRARY=str(library), CONFIG=json.dumps(config), MEMBER="call", INPUT=json.dumps({"text": "detached", "parent": 0, "request": "observer-killed"}))
    observer = subprocess.Popen(["janet", "/dev/stdin"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True, env=env)
    observer.stdin.write(script)
    observer.stdin.close()
    for _ in range(200):
        audit = sqlite3.connect('file:' + config["store"] + '?mode=ro', uri=True)
        running = audit.execute("SELECT count(*) FROM tasks t JOIN runs r ON r.id=t.run WHERE r.request='observer-killed' AND t.kind='eval' AND t.state='running'").fetchone()[0]
        audit.close()
        if running:
            break
        time.sleep(0.02)
    assert running
    observer.kill()
    observer.wait()
    for _ in range(250):
        audit = sqlite3.connect('file:' + config["store"] + '?mode=ro', uri=True)
        final = audit.execute("SELECT e.text FROM events e JOIN runs r ON r.id=e.run WHERE r.request='observer-killed' AND e.kind='completed'").fetchone()
        audit.close()
        if final:
            break
        time.sleep(0.02)
    assert final == ('42',), final
    db = sqlite3.connect('file:' + config["store"] + '?mode=ro', uri=True)
    assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    assert not db.execute('PRAGMA foreign_key_check').fetchall()
    assert db.execute("SELECT count(*) FROM sqlite_schema WHERE name='effects'").fetchone()[0] == 0
    assert db.execute('PRAGMA user_version').fetchone()[0] == 9
    db.close()
    print(f"PASS JSON/SSE recursive isolated loops, billing, dedup, last-round exit, cancellation tombstones, world acceptance/fork/restore, validated code activation/rollback, original-source summary pressure, observer SIGKILL survival, immutable ledger integrity; {time.monotonic()-started:.2f}s")
finally:
    server.shutdown()
