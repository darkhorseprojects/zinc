import base64
import http.server
import json
import os
import pathlib
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time


def encoded(value):
    return base64.b64encode(value.encode()).decode()


def completion(text=None, tools=None):
    if tools is not None:
        calls = []
        for index, code in enumerate(tools):
            calls.append({"index": index, "id": f"call-{index}", "function": {"name": "run_lua", "arguments": json.dumps({"code": code})}})
        event = {"choices": [{"delta": {"tool_calls": calls}, "finish_reason": "tool_calls"}]}
    else:
        event = {"choices": [{"delta": {"content": text}, "finish_reason": "stop"}]}
    return f"data: {json.dumps(event)}\n\ndata: [DONE]\n\n".encode()


class Model(http.server.BaseHTTPRequestHandler):
    paths = []

    def do_POST(self):
        Model.paths.append(self.path)
        size = int(self.headers["content-length"])
        value = json.loads(self.rfile.read(size))
        if self.path == "/apply-template":
            body = json.dumps({"prompt": "prompt"}).encode()
        elif self.path == "/tokenize":
            body = json.dumps({"tokens": [1]}).encode()
        elif self.path == "/v1/rerank":
            body = json.dumps({"results": [{"index": index, "relevance_score": 1.0} for index in range(len(value["documents"]))]}).encode()
        else:
            messages = value["messages"]
            question = next(message["content"] for message in messages if message["role"] == "user")
            followed = any(message["role"] == "tool" for message in messages)
            match = re.search(r"(\d+)$", question)
            coordinate = int(match.group(1)) if match else 0
            if question == "safe view" and not followed:
                body = completion(tools=["assert(self.document and self.design and self.zinc and self.fs and self.http and self.process); return 'safe-view'"])
            elif question == "safe filesystem" and not followed:
                body = completion(tools=['return self.fs([=[{"operation":"read","path":"notes.txt"}]=])'])
            elif question == "no-host view" and not followed:
                body = completion(tools=["assert(self.document and self.design and self.zinc and self.fs==nil and self.http==nil and self.process==nil); return 'no-host-view'"])
            elif question == "parallel" and not followed:
                process = {"executable": "/bin/sleep", "arguments": ["1"], "input": ""}
                if os.name == "nt": process = {"executable": "C:\\Windows\\System32\\ping.exe", "arguments": ["-n", "2", "127.0.0.1"], "input": ""}
                payload = json.dumps(process, separators=(",", ":"))
                body = completion(tools=[
                    f"self.process([==[{payload}]==]); return 'first'",
                    f"self.process([==[{payload}]==]); return 'second'",
                ])
            elif question.startswith("branch outer") and not followed:
                payload = json.dumps({"question": "branch inner", "parent": coordinate, "memory": coordinate}, separators=(",", ":"))
                body = completion(tools=[f"return self.zinc([==[{payload}]==])"])
            elif question.startswith("import outer") and not followed:
                payload = json.dumps({"question": "import inner", "parent": coordinate, "memory": coordinate}, separators=(",", ":"))
                body = completion(tools=[f"local lower=require('lower'); return lower([==[{payload}]==])"])
            else:
                body = completion(text={"branch inner": "inner branch", "import inner": "inner import"}.get(question, "complete"))
        self.send_response(200)
        self.send_header("content-type", "text/event-stream" if self.path == "/v1/chat/completions" else "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def config(actor, preset, imports=None):
    return json.dumps({"version": 1, "actor": actor, "preset": preset, "imports": imports or {}}, separators=(",", ":"))


def invoke(agent, source, input_value, config_value, imported=None):
    agents = [{"sourceDir": str(source), "entryModule": "zinc", "limits": {}}]
    imports = []
    if imported:
        agents.append({"sourceDir": str(source), "entryModule": "zinc", "limits": {}})
        imports.append({"name": "lower", "agent": 1, "config": encoded(imported)})
    request = {
        "version": 4,
        "agents": agents,
        "imports": imports,
        "input": encoded(json.dumps(input_value, separators=(",", ":"))),
        "config": encoded(config_value),
    }
    result = subprocess.run([agent, "call"], input=json.dumps(request).encode(), cwd=source, capture_output=True, timeout=20, check=True)
    value = json.loads(result.stdout)["result"]
    if "output" in value:
        return json.loads(base64.b64decode(value["output"]))
    return value


def main():
    agent = str(pathlib.Path(sys.argv[1]).resolve())
    root = pathlib.Path(sys.argv[2]).resolve()
    with tempfile.TemporaryDirectory() as temporary:
        source = pathlib.Path(temporary)
        shutil.copytree(root / "package", source, dirs_exist_ok=True)
        (source / "data").mkdir()
        (source / "state").mkdir()
        (source / "workspace").mkdir()
        (source / "workspace/notes.txt").write_text("workspace-ok")
        database = sqlite3.connect(source / "data/cygnet.db")
        database.executescript("""
CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);
INSERT INTO metadata VALUES('maximum_form_tokens','2'),('format_version','2'),('algorithm','relation-balanced-pagerank-v1');
CREATE TABLE form_scores(language TEXT,form TEXT,probability REAL);
CREATE TABLE languages(language TEXT,normalization REAL,vocabulary REAL);
CREATE TABLE form_concepts(language TEXT,form TEXT,concept INTEGER);
CREATE TABLE concept_edges(source INTEGER,target INTEGER);
CREATE TABLE concept_terms(concept INTEGER,language TEXT,term TEXT);
""")
        database.close()
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 8000), Model)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = invoke(agent, source, {"question": "base", "parent": None, "memory": 0}, config("shared", "safe"))
            assert base.get("text") == "complete", (base, Model.paths)
            assert invoke(agent, source, {"question": "safe view", "parent": base["id"], "memory": base["id"]}, config("shared", "safe"))["text"] == "complete"
            assert invoke(agent, source, {"question": "safe filesystem", "parent": base["id"], "memory": base["id"]}, config("shared", "safe"))["text"] == "complete"
            assert invoke(agent, source, {"question": "no-host view", "parent": base["id"], "memory": base["id"]}, config("shared", "no-host"))["text"] == "complete"
            started = time.monotonic()
            assert invoke(agent, source, {"question": "parallel", "parent": base["id"], "memory": base["id"]}, config("shared", "unsafe"))["text"] == "complete"
            assert time.monotonic() - started < 1.8
            assert invoke(agent, source, {"question": f"branch outer {base['id']}", "parent": base["id"], "memory": base["id"]}, config("shared", "safe"))["text"] == "complete"
            root_config = config("shared", "safe", {"lower": "Zinc without host operations."})
            lower_config = config("shared", "no-host")
            assert invoke(agent, source, {"question": f"import outer {base['id']}", "parent": base["id"], "memory": base["id"]}, root_config, lower_config)["text"] == "complete"
            failure = invoke(agent, source, {"question": "foreign", "parent": base["id"], "memory": base["id"]}, config("other", "safe"))
            assert failure["error"] == "LuaFailure"
            store = sqlite3.connect(source / "state/zinc.db")
            assert store.execute("SELECT parent,memory FROM events WHERE actor='shared' AND role='user' AND text='branch inner'").fetchone() == (base["id"], base["id"])
            assert store.execute("SELECT parent,memory FROM events WHERE actor='shared' AND role='user' AND text='import inner'").fetchone() == (base["id"], base["id"])
            assert store.execute("SELECT text FROM events WHERE role='tool' AND text LIKE '%workspace-ok%'").fetchone()
            assert [row[0] for row in store.execute("SELECT text FROM events WHERE role='tool' AND text IN ('first','second') ORDER BY id")] == ["first", "second"]
            store.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
    print("Portable Agents integration passed")


if __name__ == "__main__":
    main()
