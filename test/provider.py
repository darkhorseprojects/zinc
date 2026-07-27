#!/usr/bin/env python3
import json
import sqlite3
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from support import Zinc, check


class Provider(BaseHTTPRequestHandler):
    bodies = []

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        self.bodies.append(body)
        if any(item.get("type") == "function_call_output" for item in body["input"]):
            output = next(item["output"] for item in body["input"] if item.get("type") == "function_call_output")
            value = {"output": [{"type": "message", "content": [{"type": "output_text", "text": "continued:" + output}]}]}
        elif any(item.get("content") == "hello" for item in body["input"]):
            document = "# Tool\n```lua\nreturn require('@env').profile().username\n```"
            value = {"output": [{"type": "function_call", "name": "circuitry", "call_id": "call-1", "arguments": json.dumps({"document": document})}]}
        else:
            value = {"output": [{"type": "message", "content": [{"type": "output_text", "text": "default"}]}]}
        encoded = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *_):
        pass


server = HTTPServer(("127.0.0.1", 30000), Provider)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
zinc = Zinc()
try:
    fields = zinc.value("local a=require('@zinc'); local r={}; for k in pairs(a) do r[#r+1]=k end; table.sort(r); return r")
    assert fields == ["ask", "discard", "merge", "name", "read"], fields
    entry = zinc.agent / "zinc.md"
    explicit = check(zinc.invoke("run", "--seal", zinc.agent, entry, "--", "123456789012345678", input=b"hello"))
    assert explicit.stdout == b'continued:"local-operator"', explicit.stdout
    default = check(zinc.invoke("run", "--seal", zinc.agent, entry, "--", input=b"second"))
    assert default.stdout == b"default", default.stdout
    assert "Actor: 123456789012345678" in Provider.bodies[0]["input"][0]["content"]
    assert "Actor: local-operator" in Provider.bodies[2]["input"][0]["content"]
    connection = sqlite3.connect(zinc.database)
    assert connection.execute("SELECT actor FROM runs ORDER BY id").fetchall() == [
        ("123456789012345678",),
        ("local-operator",),
    ]
    connection.close()
    source = entry.read_text(encoding="utf-8").replace("| request_bytes | 32768", "| request_bytes |  1024")
    entry.write_text(source, encoding="utf-8")
    budget = zinc.invoke("run", "--seal", zinc.agent, entry, input=b"x" * 3000)
    assert budget.returncode != 0
    assert b"mandatory provider request exceeds request_bytes" in budget.stderr
finally:
    zinc.close()
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)
print("ok provider")
