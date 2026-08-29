local executable = os.getenv("LLAMA_SERVER") or "llama-server"
local command = string.format(
    "%q --model %q --alias rerank --host 127.0.0.1 --port 8001 --ctx-size 8192 --embedding --pooling rank --reranking --no-webui",
    executable,
    "models/llama-nemotron-rerank-1b-v2-q8_0.gguf"
)
local ok, kind, status = os.execute(command)
assert(ok, string.format("rerank server failed (%s %s)", tostring(kind), tostring(status)))
