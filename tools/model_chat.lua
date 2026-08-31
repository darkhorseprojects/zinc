local executable = os.getenv("LLAMA_SERVER") or "llama-server"
local command =
    string.format("%q --model %q --alias chat --host 127.0.0.1 --port 8000 --ctx-size 131072 --jinja --no-webui", executable, "models/LFM2.5-2.6B-Q4_K_M.gguf")
local ok, kind, status = os.execute(command)
assert(ok, string.format("chat server failed (%s %s)", tostring(kind), tostring(status)))
