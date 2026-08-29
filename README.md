# Zinc

Zinc is a small Portable Agents package with optional durable conversation results, bounded retrieval, and parallel generated Lua tools.

## Run

Start the pinned llama.cpp fork in router mode:

```sh
llama-server --host 127.0.0.1 --port 8000 --models-preset models.ini
```

Then run Zinc:

```sh
printf 'Explain the current package.' | agent run \
  --directory . --entry zinc.md \
  --trust src.models \
  --lua-memory 96MiB --process-memory 512MiB --wall-time 2m \
  -- local:example
```

`zinc.md` contains one Config fence and one short Program fence. Set `store = false` for a temporary turn or a package-relative SQLite filename for durable results. Both forms use the same loop and stop only after a completed final response.

## Models

Normal operation uses one router endpoint for:

- `POST /v1/chat/completions` with the pinned LFM2.5 GGUF;
- `POST /v1/rerank` with the pinned Nemotron reranker GGUF.

`models.lock` records the fork commit, model revisions, and file checksums. `tools/model_chat.lua` and `tools/model_rerank.lua` launch each model independently for diagnosis. See the [Models guide](https://github.com/darkhorseprojects/zinc/wiki/Models).

## Results and retrieval

Durable mode commits each completed request, reasoning item, response, tool call, and tool result before exposing its completion event. Retrieval combines a bounded recent window with older FTS candidates, Cygnet term expansion, and model reranking.

`data/cygnet.db` is a self-contained generated index. Runtime code does not open or attach the raw upstream Cygnet database. See [Results and Retrieval](https://github.com/darkhorseprojects/zinc/wiki/Results-and-Retrieval).

## Capabilities

Zinc delegates files, HTTP, processes, execution limits, generated environments, and JSONL transport to Portable Agents. Generated tools receive fresh capability values. Durable tools additionally receive `results.read`, `results.around`, and `results.ask`.

Configuration is documented in the [Configuration guide](https://github.com/darkhorseprojects/zinc/wiki/Configuration). Package authors can mount `design.md` when they want Zinc's on-demand design guide.

## Development

Lux locks Lua 5.5, lunajson, and a vendored `lsqlite3complete` build with FTS5 enabled and loadable extensions omitted.

```sh
lx test
lua tools/benchmark.lua
```

Live model tests require the pinned router and model files. See [Development](https://github.com/darkhorseprojects/zinc/wiki/Development).

License: AGPL-3.0-only.
