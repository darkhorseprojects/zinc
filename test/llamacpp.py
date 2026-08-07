#!/usr/bin/env python3
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from support import Package


class Server(BaseHTTPRequestHandler):
    bodies = []

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        self.bodies.append((self.path, body))
        if self.path == "/failure":
            self.send_response(503); self.end_headers(); self.wfile.write(b'{"error":{"message":"offline"}}'); return
        if self.path == "/chat":
            value = {"choices": [{"finish_reason": "tool_calls", "message": {
                "role": "assistant", "content": None, "reasoning_content": "inspect",
                "tool_calls": [{"id": "call-1", "type": "function", "function": {
                    "name": "run_lua", "arguments": json.dumps({"code": "return args.env.files.list('.')"})
                }}],
            }}]}
        elif self.path == "/embed":
            value = {"data": [{"index": index, "embedding": [float(index)] + [0.0] * 1023} for index in range(len(body["input"]))]}
        elif self.path == "/rerank":
            value = {"results": [{"index": 1, "relevance_score": 0.9}, {"index": 0, "relevance_score": 0.2}]}
        else:
            value = {"choices": []}
        encoded = json.dumps(value).encode()
        self.send_response(200); self.send_header("content-type", "application/json"); self.send_header("content-length", str(len(encoded))); self.end_headers(); self.wfile.write(encoded)

    def log_message(self, *_):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Server)
thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
package = Package()
try:
    package.environment["BASE"] = f"http://127.0.0.1:{server.server_port}"
    value = package.lua(r'''
local Provider=require('./src/llamacpp.lua')
local base=os.getenv('BASE')
local provider=Provider{
 chat_endpoint=base..'/chat',chat_model='LiquidAI/LFM2.5-2.6B-GGUF',embedding_endpoint=base..'/embed',embedding_model='Qwen3-Embedding-0.6B',
 rerank_endpoint=base..'/rerank',rerank_model='Qwen3-Reranker-0.6B',
}
local message,finish=provider:chat({{role='user',content='list files'}},'instructions','[]')
local arguments=provider:arguments(message.tool_calls[1])
local vectors=provider:embed({'first','second'},false)
local queries=provider:embed({'question'},true)
local ranked=provider:rerank('question',{'bad','good'})
local output=provider:toolOutput({answer=42})
local _,failure=Provider{chat_endpoint=base..'/failure',chat_model='a'}:chat({},'i','[]')
return {finish=finish,code=arguments.code,vectors=vectors,queries=queries,ranked=ranked,output=output,failure=failure}
''', ("src/llamacpp.lua",))
    assert value["finish"] == "tool_calls" and value["code"] == "return args.env.files.list('.')"
    assert len(value["vectors"]) == 2 and len(value["vectors"][0]) == 1024
    assert value["ranked"] == [{"index": 2, "score": 0.9}, {"index": 1, "score": 0.2}]
    assert json.loads(value["output"]) == {"answer": 42}
    assert value["failure"] == "offline"
    chat = next(body for path, body in Server.bodies if path == "/chat")
    assert set(chat) == {"model", "messages", "tools", "tool_choice", "parallel_tool_calls"}
    assert chat["messages"][0]["role"] == "system" and "Retrieved memory" in chat["messages"][0]["content"]
    function = chat["tools"][0]["function"]
    assert function["name"] == "run_lua" and list(function["parameters"]["properties"]) == ["code"]
    embeddings = [body for path, body in Server.bodies if path == "/embed"]
    assert embeddings[0]["input"] == ["first", "second"]
    assert embeddings[1]["input"][0].startswith("Instruct:") and "Query: question" in embeddings[1]["input"][0]
    rerank = next(body for path, body in Server.bodies if path == "/rerank")
    assert rerank["documents"] == ["bad", "good"] and "Rank prior agent events" in rerank["instruct"]
finally:
    package.close(); server.shutdown(); server.server_close(); thread.join(timeout=5)
print("ok llamacpp")
