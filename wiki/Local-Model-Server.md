# Local Model Server

`zn serve` manages the configured llama.cpp server.

```bash
zn serve
zn status
zn stop
```

The server code clones/builds llama.cpp under `~/.local/share/zinc/llama.cpp`, stores model artifacts under `~/.local/share/zinc/models`, and serves the configured OpenAI-compatible endpoint.

The default config expects:

```yaml
provider:
  base_url: http://127.0.0.1:30000/v1
  authorization: Bearer zinc
```

Use `zn status` before assuming a model is already live.
