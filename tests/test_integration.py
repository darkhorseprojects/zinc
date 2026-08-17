import json
import sqlite3
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from support import Package, success


CODE = """local child=require('results').ask('child-check')
local marker=require('host').files.read{path='marker.txt',offset=1,limit=1}
local discovered=false
for name,value in pairs(package.loaded) do
 if name=='unknown' and type(value)=='table' and value.guide then discovered=true end
end
local source_ok=pcall(require,'src.run')
local system_ok=pcall(require,'dkjson')
return {child=child,marker=marker,unknown=require('unknown').value,discovered=discovered,source_ok=source_ok,system_ok=system_ok}"""


class Server(BaseHTTPRequestHandler):
    bodies = []

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        self.bodies.append((self.path, body))
        if self.path == "/propose":
            value = {"terms": []}
        elif self.path == "/rerank":
            value = {"results": [
                {"index": index, "relevance_score": 1.0} for index in range(len(body["documents"]))
            ]}
        elif self.path == "/chat":
            messages = body["messages"]
            request = next(message["content"] for message in messages if message["role"] == "user")
            tool_result = next((message["content"] for message in messages if message["role"] == "tool"), None)
            if request == "child-check":
                events = [
                    {"choices": [{"delta": {"content": "child-ok"}, "finish_reason": None}]},
                    {"choices": [{"delta": {}, "finish_reason": "stop"}]},
                ]
            elif tool_result is not None:
                events = [
                    {"choices": [{"delta": {"content": "fin"}, "finish_reason": None}]},
                    {"choices": [{"delta": {"content": "ished"}, "finish_reason": None}]},
                    {"choices": [{"delta": {}, "finish_reason": "stop"}]},
                ]
            else:
                arguments = json.dumps({"code": CODE})
                events = [
                    {"choices": [{"delta": {"reasoning_content": "checking"}, "finish_reason": None}]},
                    {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "work", "function": {
                        "name": "run_lua", "arguments": arguments[:11],
                    }}]}, "finish_reason": None}]},
                    {"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {
                        "arguments": arguments[11:],
                    }}]}, "finish_reason": None}]},
                    {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
                ]
            encoded = b"".join(b"data: " + json.dumps(event).encode() + b"\n\n" for event in events)
            encoded += b"data: [DONE]\n\n"
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("content-length", str(len(encoded)))
            self.end_headers()
            for offset in range(0, len(encoded), 5):
                self.wfile.write(encoded[offset:offset + 5])
                self.wfile.flush()
            return
        else:
            raise AssertionError(self.path)
        encoded = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *_):
        pass


def test_complete_zinc_execution_persists_each_completed_result():
    Server.bodies = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), Server)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    package = Package()
    try:
        (package.work / "marker.txt").write_text("marker")
        (package.package / "unknown.md").write_text(
            "# Unknown\n\n## Guide\n\nUnknown guide.\n\n## Program\n\n```lua\n"
            "return {guide=document.Unknown.Guide,value='available'}\n```\n"
        )
        source = (package.package / "zinc.md").read_text()
        base = f"http://127.0.0.1:{server.server_port}"
        source = source.replace("http://127.0.0.1:8000/v1/chat/completions", base + "/chat")
        source = source.replace("http://127.0.0.1:8002/propose", base + "/propose")
        source = source.replace("http://127.0.0.1:8001/rerank", base + "/rerank")
        source = source.replace("| semantic_depth | 1 |", "| semantic_depth | 0 |")
        (package.package / "zinc.md").write_text(source)
        output = success(package.run(
            "zinc.md", input=b"integration", arguments=("discord-42",),
            authorize=("src.host", "src.store", "src.models"),
            register={"host": "host.md", "design": "design.md", "unknown": "unknown.md"}, timeout=60,
        ))
        events = [json.loads(line) for line in output.stdout.splitlines()]
        assert [event["type"] for event in events] == [
            "reasoning", "reasoning_complete", "tool_call", "tool_result",
            "response", "response", "response_complete", "store"
        ]
        assert events[0] == {"type": "reasoning", "text": "checking"}
        assert all(fragment in events[3]["text"] for fragment in [
            '"unknown":"available"', '"discovered":true', '"source_ok":false', '"system_ok":false'
        ])
        assert events[4:6] == [{"type": "response", "text": "fin"}, {"type": "response", "text": "ished"}]
        assert events[-1] == {"type": "store", "result": 7, "start": 1}

        chats = [body for path, body in Server.bodies if path == "/chat"]
        assert len(chats) == 3
        assert [message["role"] for message in chats[-1]["messages"]] == ["system", "system", "user", "assistant", "tool"]
        assert all(chat["parallel_tool_calls"] is False for chat in chats)
        proposals = [body for path, body in Server.bodies if path == "/propose"]
        assert all(
            body["semantic_language"] == "en" and body["semantic_depth"] == 0
            and body["semantic_attention_cutoff"] == 0 and body["maximum_terms"] <= 512
            for body in proposals
        )

        connection = sqlite3.connect(package.home / ".agents/zinc/store/zinc.sqlite3")
        rows = connection.execute("SELECT id,actor,start,role,text FROM results ORDER BY id").fetchall()
        names = {row[0] for row in connection.execute("SELECT name FROM sqlite_master")}
        connection.close()
        assert [(row[0], row[2], row[3]) for row in rows] == [
            (1, 1, "user"), (2, 1, "assistant"), (3, 1, "assistant"),
            (4, 4, "user"), (5, 4, "assistant"), (6, 1, "tool"), (7, 1, "assistant"),
        ]
        assert rows[4][4] == "child-ok" and rows[-1][4] == "finished"
        assert "runs" not in names and "result_fts" in names
    finally:
        package.close()
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
