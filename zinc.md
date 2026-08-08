# Zinc

## Instructions

You are Zinc. Answer the request. Use `run_lua` when tools or child runs are needed. In `run_lua`, use standard Lua positional arguments and always `return` the result:
- `return args.env.files.read("README.md")`
- `return args.env.files.list(".")`
- `return args.env.files.write("path", "text")`
- `return args.env.shell("inspect", "command")`
- `return args.run.merge("child request")`

Do not use named arguments (e.g. `path=...` is invalid in Lua) and do not use `print`. Paths are relative to the current workspace root `.`. Use retrieved memory when relevant.

## Settings

| field | value | purpose |
| --- | --- | --- |
| store | store | Local SQLite Store directory. |
| actor | local | Default Memory actor. |
| chat_endpoint | http://127.0.0.1:8000/v1/chat/completions | llama.cpp agent endpoint. |
| chat_model | LiquidAI/LFM2.5-2.6B-GGUF | llama.cpp agent model name. |
| embedding_endpoint | http://127.0.0.1:8001/v1/embeddings | llama.cpp embedding endpoint. |
| embedding_model | Qwen3-Embedding-0.6B | llama.cpp embedding model name. |
| rerank_endpoint | http://127.0.0.1:8002/v1/rerank | llama.cpp reranker endpoint. |
| rerank_model | Qwen3-Reranker-0.6B | llama.cpp reranker model name. |
| store_bytes | 8388608 | Maximum prior Store data considered, scanning backward from the tail. |
| context_bytes | 65536 | Maximum retrieved-memory JSON placed in a Run. |
| hops | 2 | Maximum retrieval bridge rounds at Run start. |

## Program

```lua
local settings = {}
for _, row in ipairs(document.Zinc.Settings) do settings[row.field] = row.value end
for _, name in ipairs({"store_bytes", "context_bytes", "hops"}) do
    settings[name] = assert(math.tointeger(tonumber(settings[name])), name .. " must be an integer")
    assert(settings[name] > 0, name .. " must be positive")
end
for _, name in ipairs({
    "store", "actor", "chat_endpoint", "chat_model", "embedding_endpoint", "embedding_model", "rerank_endpoint", "rerank_model",
}) do
    assert(type(settings[name]) == "string" and settings[name] ~= "", name .. " must be nonempty text")
end
local function prose(value)
    if type(value) ~= "table" then return tostring(value or "") end
    local parts = {}
    for _, item in ipairs(value) do table.insert(parts, prose(item)) end
    return table.concat(parts, "\n\n")
end
local store = require("./src/store.lua")(settings)
local provider = require("./src/llamacpp.lua")(settings)
local memory = require("./src/memory.lua")(settings, store, provider)
local environment = require("./src/env.lua")(settings, require("./env.md"))
local format = function(m) return type(m) == "table" and m.content or tostring(m or "") end
local zinc = require("./src/run.lua") {
    name = "zinc",
    actor = settings.actor,
    store = store,
    memory = memory,
    provider = provider,
    environment = environment,
    builder = require("./builder.lua")(require("./docs.md")),
    format = format,
    instructions = table.concat({prose(document.Zinc.Instructions), prose(environment.guide)}, "\n\n"),
}
if args.input == nil then return zinc end
return zinc.ask(args.input, args.arguments[1])
```
