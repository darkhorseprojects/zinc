# Zinc

Zinc (`zn`) is a small Zig runtime for local Circuitry agent loops.

It does a narrow job:

- compile the Zinc-shaped Circuitry graph into a runtime plan
- keep project sessions as JSONL
- call an OpenAI-compatible local model server
- expose the graph-approved tools
- print the assistant's final `response`

Tools run inside the agent turn. They are session runtime events, not Circuitry graph nodes.

## install

```bash
git clone https://github.com/darkhorseprojects/zinc.git
cd zinc
./scripts/install-linux.sh
```

The install script writes:

```text
~/.local/bin/zn
~/.local/bin/zn-setup-turboquant
~/.local/share/zinc/graphs/
~/.local/share/zinc/prompts/
~/.local/share/zinc/compiled/plan.json
~/.config/zinc/config.toml
```

Build the supported TurboQuant llama-server:

```bash
zn-setup-turboquant
```

Start and stop the local server:

```bash
zn up
zn down
```

Basic use:

```bash
zn validate
zn compile
zn "summarize this repo"
zn --continue "follow up in the last session for this directory"
zn --session <id> "resume this session id"
```

## config

Zinc reads config in this order:

```text
.zinc/config.toml
zinc.toml
~/.config/zinc/config.toml
installed defaults
```

The current scalar runtime keys are:

```toml
graph = "graphs/zinc-loop.circuitry.yaml"
compiled_plan = ".zinc/compiled/plan.json"
provider_base_url = "http://127.0.0.1:30000/v1"
max_retries = 5
default_model = "gemma-heretic"
```

Model config uses TOML tables:

```toml
[models.gemma-heretic]
engine = "llama-cpp-turboquant"
alias = "gemma-4-96e-a4b-heretic-tq"
hf_repo = "WaveCut/Gemma-4-96E-A4B-Heretic-TQ"
hf_file = "Gemma-4-96E-A4B-Heretic-TQ3_1S.gguf"
cache_type_k = "q8_0"
cache_type_v = "turbo3"
fit_ctx = 8192
vram_allocation_percent = 87.5
temperature = 0.5
```

`max_retries` is Zinc's cap for clean turn-correction retries, such as invalid final JSON or unavailable tool calls. Transient provider failures are retried immediately before they surface. Neither case creates graph branches.

## model server

Zinc talks to a local OpenAI-compatible endpoint. The default is:

```text
http://127.0.0.1:30000/v1
```

The default install is tuned for the Gemma Heretic TurboQuant GGUF on a 16GB NVIDIA card. The launcher:

```text
uses WaveCut's TurboQuant llama.cpp branch
serves Gemma-4-96E-A4B-Heretic-TQ3_1S.gguf
uses alias gemma-4-96e-a4b-heretic-tq
fits at least 8192 tokens of context
caps VRAM by vram_allocation_percent
uses q8_0 K cache and turbo3 V cache
runs one server slot
```

`zn compile` fails when a graph asks for a model id Zinc cannot find in config. `zn up [model-id]` starts the configured model server and records its pid. Without an argument, `zn up` serves the graph-resolved model, or `default_model` when the graph says `inherit`.

## commands from source

```bash
zig build
zig build test
./zig-out/bin/zn validate
./zig-out/bin/zn compile
./zig-out/bin/zn up
./zig-out/bin/zn down
./zig-out/bin/zn clean
./zig-out/bin/zn session-dir
./zig-out/bin/zn "summarize this repo"
./zig-out/bin/zn run --continue "follow up"
```

## source map

```text
src/main.zig           CLI dispatch
src/commands.zig       validate, compile, run, session-dir
src/engine.zig         compiled agent loop
src/provider.zig       OpenAI-compatible HTTP calls
src/tools.zig          builtin tools
src/plan.zig           compiled runtime plan loading
src/server.zig         zn up/down
src/clean.zig          cleanup command
src/config.zig         config and model lookup
src/session.zig        JSONL sessions
src/files.zig          file/syscall helpers
src/graph.zig          Zinc's Circuitry subset
```

## default loop

The default graph is `graphs/zinc-loop.circuitry.yaml`. It links `graphs/zinc-context-recovery.circuitry.yaml`.

The runtime path is:

```text
session log + current user turn
  -> recovered_context
  -> assistant
  -> final {"response":"..."}
```

`zn run` and bare `zn "prompt"` refresh the compiled plan before running. The context recovery node sees the session JSONL and returns compact context for the assistant. The assistant receives that context as untrusted data.

Zinc can also run a graph path for one root turn:

```bash
zn graphs/custom.circuitry.yaml
zn run graphs/custom.circuitry.yaml "do the thing"
zn graphs/custom.circuitry.yaml --input brief=hello --input mode=fast
zn graphs/custom.circuitry.yaml --inputs-json '{"brief":"hello"}'
```

For now, graph-path execution uses Zinc's runtime subset.

## final output contract

The assistant's final output must match graph `expect`:

```yaml
expect:
  response: str
```

Zinc parses the model output as JSON and prints only `response`. If final output is invalid, Zinc records a runtime contract failure and retries the turn cleanly until `max_retries` is spent. It does not accept markdown wrapped around the final answer.

Tool calls keep a turn going. Final JSON ends the turn.

## tools

Graphs choose the tools an agent may use:

```yaml
resources:
  assistant:
    type: agent
    tools:
      - read
      - write
      - edit
      - bash
      - request_circuitry_run
```

Zinc resolves those names at compile time and refuses unknown tools. At runtime it exposes only the compiled list and rejects tool calls outside that list.

Current builtin tools:

```text
read
write
edit
bash
request_circuitry_run
```

`bash` is the general adapter to the local machine and network. `write`, `edit`, and `bash` can change local state.

`request_circuitry_run` does not call Zinc recursively. It returns a pending approval message telling the user-facing turn what graph command to run if approved.

## sessions

Each project keeps sessions in `.zinc/sessions/`:

```text
.zinc/sessions/last
.zinc/sessions/<session-id>.jsonl
```

The file is JSONL. Conversation and runtime are separate:

```jsonl
{"type":"session","version":1,"runtime":"zinc","id":"s...","createdAt":0}
{"type":"message","timestamp":0,"message":{"role":"user","content":"..."}}
{"type":"runtime","timestamp":0,"phase":"context_recovery","event":"model_output","content":"..."}
{"type":"runtime","timestamp":0,"phase":"tool","event":"tool_call","tool":"bash","content":"..."}
{"type":"runtime","timestamp":0,"phase":"tool","event":"tool_result","tool":"bash","content":"..."}
{"type":"message","timestamp":0,"message":{"role":"assistant","content":"..."}}
```

`--continue` uses the last session id in this directory. `--session <id>` resumes a specific session.

## cleanup

Cleanup is dry-run unless you pass `--yes`.

```bash
zn clean                 # local compiled artifacts
zn clean --yes
zn clean sessions        # local session history
zn clean sessions --yes
zn clean all             # local compiled artifacts and sessions
zn clean global          # global Zinc state/log files
zn clean global --yes
zn clean build           # global TurboQuant build checkout
zn clean build --yes
zn clean global all      # global state/logs and build checkout
```

Global cleanup refuses to remove state while the recorded Zinc server is running. Run `zn down` first.

## status

Zinc is early. The public seed is useful, but small on purpose. Expect the config keys and graph subset to move as the runtime gets sharper.
