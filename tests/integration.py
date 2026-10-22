import base64
import concurrent.futures
import http.server
import json
import os
import pathlib
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time

root = pathlib.Path.cwd()
assert (root / "models.ini").read_bytes() == (pathlib.Path(os.environ["JANET_PATH"]) / "zinc/models.ini").read_bytes()
program = dict(sourceDir=str(root), entryModule="zinc.md", dependencies={"library": os.environ["JANET_PATH"]})
os.environ.update(GIT_AUTHOR_NAME="Zinc CI", GIT_AUTHOR_EMAIL="zinc@example.invalid",
                  GIT_COMMITTER_NAME="Zinc CI", GIT_COMMITTER_EMAIL="zinc@example.invalid")


def invoke(entry, value, config, failure=False):
    packet = dict(version=2, program=dict(program, entry=entry),
                  input=base64.b64encode((json.dumps(value) if value is not None else "").encode()).decode(),
                  config=base64.b64encode(json.dumps(config).encode()).decode())
    process = subprocess.run([shutil.which("agent"), "spawn", "16777216", "10"],
                             input=json.dumps(packet) + "\n", text=True, capture_output=True, timeout=60)
    frames = [json.loads(line) for line in process.stdout.splitlines()]
    assert process.returncode == 0 and frames[-1]["type"] == ("error" if failure else "result"), (frames, process.stderr)
    return frames[-1] if failure else json.loads(base64.b64decode(frames[-1]["output"]))


class Model(http.server.BaseHTTPRequestHandler):
    requests = []

    def do_GET(self):
        self.requests.append(("GET", self.path, None))
        body = json.dumps(dict(data=[dict(id="mock", context_length=65536,
                                        top_provider=dict(context_length=65536), supported_parameters=[],
                                        architecture=dict(input_modalities=["text"]))])).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append(("POST", self.path, request))
        body = json.dumps(dict(choices=[dict(finish_reason="stop", message=dict(role="assistant", content="native answer"))])).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


with tempfile.TemporaryDirectory(dir=root) as directory:
    path = pathlib.Path(directory)
    subprocess.run(["git", "init", "-q", "--initial-branch=main", directory], check=True)
    world = path / "nested world" / "世界.janet"
    world.parent.mkdir()
    world.write_text("(defn double [x] (* 2 x))", encoding="utf-8")
    relative = world.relative_to(path).as_posix()
    subprocess.run(["git", "-C", directory, "add", "--", relative], check=True)
    subprocess.run(["git", "-C", directory, "commit", "-qm", "initial world"], check=True)
    transport = path / "transport.janet"
    transport.write_text('''(import spork/json :as json)
(defn request [url method body headers]
  {:error :ok :status 200 :body (json/encode
    (if (= method "GET") {:data [{:id "mock" :context_length 65536 :top_provider {:context_length 65536} :supported_parameters ["tools"] :architecture {:input_modalities ["text" "image"]}}]}
      {:choices [{:finish_reason "stop" :message {:role "assistant" :content "mock answer"}}]}))})''', encoding="utf-8")
    config = dict(source="verify", world="verify", store=str(path / "history.db"), file=str(world), repl=True,
                  inference=True, search=False, parallel=1, chat="openrouter:mock",
                  providers={"openrouter": {"url": "https://mock.invalid", "transport": {"module": str(transport)}}})
    assert invoke("describe", None, config)["contract"] == "inquiry-v3"
    inquiry = dict(code="(double 21)", request="code", author="human", at="2026-01-01T00:00:00.000Z")
    completed = invoke("self", inquiry, config)
    assert completed["text"] == "42" and completed["final"]
    assert invoke("self", inquiry, config) == completed
    with sqlite3.connect(config["store"]) as db:
        start = db.execute("SELECT id FROM events WHERE kind='user' AND json_extract(data,'$.input.request')='code'").fetchone()[0]
    ranged = invoke("self", dict(inquiry, request="range", parent=start, memory_range={"end": start}), config)
    assert ranged["text"] == "42" and ranged["memory_range"] == {"start": start, "end": start}
    image = dict(text="image", images=[dict(type="image/png", data="YQ==")], request="image", author="human", at=inquiry["at"])
    invoke("self", image, config)
    assert invoke("self", dict(image, images=[dict(type="image/png", data="YR==")]), config)["text"] == "mock answer"
    with sqlite3.connect(config["store"]) as db:
        assert db.execute("SELECT bytes FROM images LIMIT 1").fetchone()[0] == b"a"
    page = invoke("events", dict(run=completed["run"]), config)
    assert [frame["type"] for frame in page["events"]] == ["start", "display", "display"]
    assert page["events"][1]["language"] == "janet" and page["events"][2]["body"] == "42"
    assert "body" not in completed and completed["text"] == "42"
    assert invoke("abort", dict(request="code", reason="already complete"), config)["state"] == "completed"
    record = dict(key="passive", author="human", at=inquiry["at"], text="```janet\n(error :never-evaluate)\n```")
    assert invoke("record", dict(records=[record]), config) == invoke("record", dict(records=[record]), config)
    child = dict(inquiry, request="recursive", code='(await (self {:text "child"}))')
    assert "mock answer" in invoke("self", child, config)["text"]
    temporary = dict(inquiry, request="private", persist=False, code='"PRIVATE_PAYLOAD"')
    assert invoke("self", temporary, config)["text"] == "PRIVATE_PAYLOAD"
    invoke("abort", dict(request="cancel-before-admission", reason="cancel"), config)
    invoke("self", dict(inquiry, request="cancel-before-admission"), config, failure=True)
    with concurrent.futures.ThreadPoolExecutor() as pool:
        original = pool.submit(invoke, "self", dict(inquiry, request="duplicate", code="(ev/sleep 1) (double 21)"), config)
        deadline = time.monotonic() + 10
        owner = None
        while time.monotonic() < deadline:
            with sqlite3.connect(config["store"]) as db:
                owner = db.execute("SELECT id,owner FROM call_controls WHERE request='duplicate' AND EXISTS(SELECT 1 FROM events WHERE call=call_controls.id AND kind='call-attempt')").fetchone()
            if owner:
                break
            time.sleep(.01)
        assert owner
        invoke("task", dict(task=owner[0], owner=owner[1]), config, failure=True)
        assert original.result()["text"] == "42"
    invoke("self", dict(inquiry, request="handoff", code='(self {:code "(double 21)"})'), config)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        with sqlite3.connect(config["store"]) as db:
            child = db.execute("SELECT c.state FROM call_controls c JOIN call_controls p ON c.parent=p.id WHERE p.request='handoff'").fetchone()
        if child and child[0] == "done":
            break
        time.sleep(.01)
    assert child and child[0] == "done"
    records = [dict(record, key=f"summary-{i}", text=(f"fact {i} " * 100)) for i in range(32)]
    invoke("record", dict(records=records), config)
    assert invoke("self", dict(text="summarize", request="summary", author="human", at=inquiry["at"]),
                  dict(config, **{"context-quota": 4096, "summary-quota": 128}))["text"] == "mock answer"
    with sqlite3.connect(config["store"]) as db:
        assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        assert db.execute("PRAGMA user_version").fetchone()[0] == 1
        assert db.execute("SELECT count(*) FROM events WHERE kind='user' AND json_extract(data,'$.input.request')='code'").fetchone()[0] == 1
        assert not db.execute("SELECT count(*) FROM events WHERE text LIKE '%PRIVATE_PAYLOAD%' OR data LIKE '%PRIVATE_PAYLOAD%'").fetchone()[0]
        assert db.execute("SELECT state FROM call_controls WHERE request='cancel-before-admission'").fetchone()[0] == "cancelled"
    save_config = dict(config, capabilities={"save": {}})
    invoke("self", dict(inquiry, request="save", code='(spit (world :current-file) "(defn double [x] (* 3 x))") (save "change")'), save_config)
    assert subprocess.check_output(["git", "-C", directory, "show", f"HEAD:{relative}"], text=True) == "(defn double [x] (* 3 x))"
    assert invoke("self", dict(inquiry, request="saved-head"), config)["text"] == "63"
    invoke("self", dict(inquiry, request="branch", code='(spit (world :current-file) "(defn double [x] (* 4 x))") (save "branch" {:branch "experiment"})'), save_config)
    invoke("self", dict(inquiry, request="merge", code='(save "merge" {:merge "refs/heads/experiment"})'), save_config)
    assert invoke("self", dict(inquiry, request="merged-head"), config)["text"] == "84"
    world.write_text("(def dirty true)", encoding="utf-8")
    invoke("self", dict(inquiry, request="dirty", code='(spit (world :current-file) "(defn double [x] (* 5 x))") (save "preserve dirty file")'), save_config)
    assert world.read_text(encoding="utf-8") == "(def dirty true)"
    assert subprocess.check_output(["git", "-C", directory, "show", f"HEAD:{relative}"], text=True) == "(defn double [x] (* 5 x))"
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            native = dict(config, repl=False, store=str(path / "native.db"),
                          providers={"openrouter": {"url": f"http://127.0.0.1:{server.server_port}"}})
            assert invoke("models", dict(role="chat"), native) == [dict(ref="openrouter:mock", name="mock")]
            value = dict(text="native transfer", request="native", author="human", at=inquiry["at"])
            assert invoke("self", value, native)["text"] == "native answer"
            assert invoke("self", value, native)["text"] == "native answer"
            posts = [request for method, route, request in Model.requests if method == "POST" and route == "/v1/chat/completions"]
            assert len(posts) == 1 and posts[0]["stream"] is False and posts[0]["model"] == "mock"
        finally:
            server.shutdown()
            worker.join()
print("Zinc integration passed")
