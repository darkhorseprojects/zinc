import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from support import Package


class Server(BaseHTTPRequestHandler):
    bodies = []

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        self.bodies.append((self.path, body))
        if self.path == "/chat":
            values = [
                {"choices": [{"delta": {"reasoning_content": "think"}, "finish_reason": None}]},
                {"choices": [{"delta": {"content": "answer"}, "finish_reason": None}]},
                {"choices": [{"delta": {}, "finish_reason": "stop"}]},
            ]
            encoded = b"".join(b"data: " + json.dumps(value).encode() + b"\n\n" for value in values)
            encoded += b"data: [DONE]\n\n"
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.end_headers()
            self.wfile.write(encoded)
            return
        if self.path == "/propose":
            value = {"terms": ["ocean"], "truncated": False}
        elif self.path == "/bad-propose":
            value = {"terms": ["ocean"]}
        elif self.path == "/rerank":
            value = {"results": [
                {"index": index, "relevance_score": float(len(body["documents"]) - index)}
                for index in range(len(body["documents"]))
            ]}
        elif self.path == "/failure":
            self.send_response(503)
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"offline"}}')
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


def test_chat_streams_while_proposal_and_rerank_are_buffered():
    Server.bodies = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), Server)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    package = Package()
    try:
        package.environment["BASE"] = f"http://127.0.0.1:{server.server_port}"
        value = package.lua(r'''
local base=os.getenv('BASE')
local models=require('src.models').new({
 chat={endpoint=base..'/chat',model='chat'},propose={endpoint=base..'/propose'},
 rerank={endpoint=base..'/rerank',model='reranker'},
},require('src.sse'))
local iterator=assert(models:chat{{role='system',content='trusted'},{role='user',content='request'}})
local events={};while true do local event,failure=iterator();if not event then assert(not failure,failure);break end;events[#events+1]=event end
local proposed,truncated=models:propose('stream',3,0,512)
local ranked,ranked_count=models:rerank('question',{'one','two'},1048576)
local one=models.encode{model='reranker',query='question',documents={'one'},top_n=1}
local limited,limited_count=models:rerank('question',{'one','two'},#one)
return{events=events,proposed=proposed,truncated=truncated,ranked=ranked,ranked_count=ranked_count,limited=limited,limited_count=limited_count}
''', ("src.models",))
        assert [event["type"] for event in value["events"]] == ["reasoning", "response", "finish"]
        assert value["proposed"] == ["ocean"] and value["truncated"] is False
        assert value["ranked"] == [{"index": 1, "score": 2}, {"index": 2, "score": 1}]
        assert value["ranked_count"] == 2
        assert value["limited"] == [{"index": 1, "score": 1}] and value["limited_count"] == 1
        bodies = dict(Server.bodies)
        assert bodies["/propose"] == {
            "text": "stream", "semantic_steps": 3, "cygnet_attention_minimum": 0, "maximum_terms": 512
        }
        assert bodies["/rerank"] == {
            "model": "reranker", "query": "question", "documents": ["one"], "top_n": 1
        }
    finally:
        package.close()
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_model_failures_are_explicit():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Server)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    package = Package()
    try:
        package.environment["BASE"] = f"http://127.0.0.1:{server.server_port}"
        value = package.lua(r'''
local base=os.getenv('BASE');local models=require('src.models').new({
 chat={endpoint='unused',model='chat'},propose={endpoint=base..'/failure'},rerank={endpoint=base..'/failure',model='reranker'},
},require('src.sse'))
local proposed,proposal_failure=models:propose('x',1,0,10);local ranked,rank_failure=models:rerank('q',{'d'},1000)
local oversized,oversized_failure=models:rerank('q',{'d'},1)
local invalid=require('src.models').new({chat={endpoint='unused',model='chat'},propose={endpoint=base..'/bad-propose'},rerank={endpoint='unused',model='reranker'}},require('src.sse'))
local malformed,malformed_failure=invalid:propose('x',1,0,10)
return{proposed=proposed,proposal_failure=proposal_failure,ranked=ranked,rank_failure=rank_failure,oversized=oversized,oversized_failure=oversized_failure,malformed=malformed,malformed_failure=malformed_failure}
''', ("src.models",))
        assert value.get("proposed") is None and value["proposal_failure"] == "offline"
        assert value.get("ranked") is None and value["rank_failure"] == "offline"
        assert value.get("oversized") is None and "first reranker passage" in value["oversized_failure"]
        assert value.get("malformed") is None and value["malformed_failure"] == "proposal response is invalid"
    finally:
        package.close()
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
