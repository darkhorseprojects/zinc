#!/usr/bin/env python3
import json
import sqlite3
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from support import Package, success

CODE = '''local child = args.run.merge("child-check")
local listing = args.env.files.list(".")
local process = args.env.shell("inspect", "printf integrated")
if process.status ~= 0 then error(process.stderr) end
return {child=child, stdout=process.stdout, listing=listing}'''


class Server(BaseHTTPRequestHandler):
    bodies = []

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        self.bodies.append((self.path, body))
        if self.path == "/chat":
            messages = body["messages"]
            if any(item.get("role") == "user" and item.get("content") == "child-check" for item in messages):
                message = {"role": "assistant", "content": "child-ok"}
            elif any(item.get("role") == "tool" for item in messages):
                message = {"role": "assistant", "content": "finished"}
            else:
                message = {"role": "assistant", "content": None, "tool_calls": [{
                    "id": "work-1", "type": "function", "function": {"name": "run_lua", "arguments": json.dumps({"code": CODE})}
                }]}
            value = {"choices": [{"finish_reason": "tool_calls" if message.get("tool_calls") else "stop", "message": message}]}
        else:
            raise AssertionError(self.path)
        encoded = json.dumps(value).encode()
        self.send_response(200); self.send_header("content-type", "application/json"); self.send_header("content-length", str(len(encoded))); self.end_headers(); self.wfile.write(encoded)

    def log_message(self, *_):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Server)
thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
package = Package()
try:
    (package.work / "marker.txt").write_text("marker")
    source = (package.package / "zinc.md").read_text()
    source = source.replace("http://127.0.0.1:8000/v1/chat/completions", f"http://127.0.0.1:{server.server_port}/chat")
    (package.package / "zinc.md").write_text(source)
    authority = ("src/store.lua", "src/memory.lua", "src/llamacpp.lua", "src/env.lua")
    result = success(package.run("zinc.md", input=b"integration", arguments=("discord-42",), authority=authority, timeout=60))
    assert result.stdout.decode() == "finished"
    chats = [body for path, body in Server.bodies if path == "/chat"]
    assert len(chats) == 3
    first = chats[0]
    assert first["messages"][1] == {"role": "user", "content": "integration"}
    assert "temperature" not in first and "max_tokens" not in first
    assert first["tools"][0]["function"]["name"] == "run_lua"
    connection = sqlite3.connect(package.home / ".agents/zinc/store/zinc.sqlite3")
    slices = [json.loads(row[0]) for row in connection.execute("SELECT data FROM slices ORDER BY idx")]
    connection.close()
    tool = next(item for item in slices if item.get("source") == "tool")
    output = json.loads(tool["value"]["content"])
    assert output["child"] == "child-ok" and output["stdout"] == "integrated" and "marker.txt" in output["listing"]
    assert any(item.get("type") == "merged" for item in slices)
    assert slices[-1] == {"type": "response", "source": "zinc", "value": "finished"}
finally:
    package.close(); server.shutdown(); server.server_close(); thread.join(timeout=5)
print("ok integration")
