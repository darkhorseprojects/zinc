# Zinc

Zinc (`zn`) is a tiny Zig 0.16.0 runtime for Circuitry-native local agent loops.

It keeps the core split simple:

- **cli/program** handles commands, cleanup, server lifecycle, and graph compilation
- **engine** runs a compiled agent leaf: plan, session, provider, tools, expected output
- **tools** are callable capabilities during execution of an agent leaf
- **circuitry** graphs describe execution flow
- **sessions** are project-local JSONL logs under `.zinc/sessions/`

Tools are runtime events inside an agent/leaf node. They are not graph nodes.

## Install on Arch/Linux

```bash
git clone https://github.com/darkhorseprojects/zinc.git
cd zinc
./scripts/install-linux.sh
```

This installs only:

```text
~/.local/bin/zn
~/.local/bin/zn-setup-turboquant
```

Build Zinc's supported TurboQuant llama-server:

```bash
zn-setup-turboquant
```

Start the local model server in the background:

```bash
zn up
```

Stop it later:

```bash
zn down
```

Then:

```bash
zn validate
zn compile
zn "summarize this repo"
zn --continue "follow up in the last session for this directory"
zn --session <id> "resume a specific session"
```

## Model server

Zinc talks to an OpenAI-compatible local llama-server at:

```text
http://127.0.0.1:30000/v1
```

Circuitry declares model ids (`runtime.model` or per-agent `model`). Zinc provides those ids through `~/.config/zinc/config.toml` and `.zinc/config.toml`. The default graph declares:

```yaml
runtime:
  provider: zinc
  model: gemma-heretic
```

The bundled `gemma-heretic` provider uses WaveCut's TurboQuant llama.cpp branch, as required by this GGUF. The served model alias is:

```text
gemma-4-96e-a4b-heretic-tq
```

The launcher is deliberately not a profile system. It is one opinionated command for the 16GB RTX 5070 Ti path:

```text
llama-cpp-turboquant / llama-server
WaveCut/Gemma-4-96E-A4B-Heretic-TQ with Gemma-4-96E-A4B-Heretic-TQ3_1S.gguf
minimum 8,192 token context; context may grow only inside Zinc's VRAM allocation cap
GPU layers fitted to the VRAM allocation cap
TurboQuant K cache: q8_0
TurboQuant V cache: turbo3
Flash Attention
Jinja templates
reasoning off
prompt RAM cache disabled
one server slot
```

Zinc caps llama-server's fitting budget with model config. The default is `87.5`, which is 14GB on a 16GB card. The launcher converts the percentage into `--fit-target` margin, leaves `--ctx-size` unset, and sets `--fit-ctx 8192`; llama-server must fit the model and runtime buffers first, may spend only the remaining allocation budget on context/KV cache, and must leave everything beyond the allocation cap untouched.

Model providers are TOML tables:

```toml
default_model = "gemma-heretic"

[models.gemma-heretic]
engine = "llama-cpp-turboquant"
alias = "gemma-4-96e-a4b-heretic-tq"
hf_repo = "WaveCut/Gemma-4-96E-A4B-Heretic-TQ"
hf_file = "Gemma-4-96E-A4B-Heretic-TQ3_1S.gguf"
cache_type_k = "q8_0"
cache_type_v = "turbo3"
fit_ctx = 8192
vram_allocation_percent = 87.5
```

`zn compile` fails if the graph asks for a model id Zinc cannot provide. `zn up [model-id]` starts the configured server in the background and records its pid under Zinc state; without an argument it serves the graph-resolved model, falling through to `default_model` when the graph says `inherit`. `zn down` stops that recorded server.

## Commands from source

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

## Runtime shape

The source is split by ownership:

```text
src/main.zig           CLI dispatch
src/commands.zig       validate, compile, run, session-dir
src/engine.zig         compiled agent loop
src/provider.zig       OpenAI-compatible HTTP provider
src/tools.zig          builtin tool execution
src/plan.zig           compiled runtime plan loading
src/server.zig         zn up/down
src/clean.zig          cleanup command
src/config.zig         config and model lookup
src/session.zig        JSONL sessions and context log input
src/files.zig          file/syscall helpers
src/graph.zig          Zinc-supported Circuitry graph subset
```

## Default loop

The default graph is `graphs/zinc-loop.circuitry.yaml`. It is a Circuitry v0.2.99 resources graph that links `graphs/zinc-context-recovery.circuitry.yaml`. The linked fragment owns `session_log -> recovered_context`; the main loop owns `user_turn -> assistant`.

`zn compile` resolves linked graph files, validates Zinc's supported loop shape, and writes a compact runtime plan. `zn run` and bare `zn "prompt"` consume that compiled Circuitry artifact directly: the active session log is sent through the context recovery node first, then the assistant receives `user_turn` plus `recovered_context`. The context is graph-visible instead of hidden metadata sideband.

Zinc can help author arbitrary Circuitry v0.2.99 graphs through tools and prompt packs. Zinc's own hot runtime currently compiles the Zinc loop shape, not every possible Circuitry program shape.

A root/user-facing invocation can replace the default runtime graph for one run:

```bash
zn graphs/custom.circuitry.yaml
zn run graphs/custom.circuitry.yaml "do the thing"
zn graphs/custom.circuitry.yaml --input brief=hello --input mode=fast
zn graphs/custom.circuitry.yaml --inputs-json '{"brief":"hello"}'
```

Those inline inputs are a CLI convenience for the root turn; runtime nodes still do not directly run graphs recursively.

The assistant's final output is governed by graph `expect`:

```yaml
expect:
  response: str
```

Zinc validates the model's final JSON against that contract and prints only `response`. If the model emits invalid final JSON, Zinc asks once for a valid `expect` response instead of accepting formatting slop. Tool calls, not a `done` flag, drive continued work inside a turn.

## Tools, prompt packs, and Circuitry authoring

Graphs declare the tools an agent may use:

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

`zn compile` resolves those names against Zinc's builtin tool registry and fails on unknown tools. At runtime Zinc exposes only the compiled tool list to the model and refuses tool calls not allowed by the graph.

Current builtin tools:

```text
read
write
edit
bash
request_circuitry_run
```

`request_circuitry_run` does not execute recursively. It returns a pending approval message telling the root/user-facing invocation to run `zn file.circuitry.yaml` or `zn run file.circuitry.yaml` if approved.

Prompt packs live in `prompts/` from source and are installed to `~/.local/share/zinc/prompts/`. `prompts/circuitry-author.md` is injected when the graph asks for Circuitry tools or mentions `circuitry-author`, teaching the agent v0.2.99 resource/link graph authoring rules.

Tool trust model: tools execute on the local machine from the current working directory, and path-taking tools can mutate files. Bash is the general interface to local and network state; grant `write`, `edit`, and `bash` only to graphs that should be allowed to change local state.

## Cleanup

Cleanup is dry-run by default. Add `--yes` to remove the printed paths.

```bash
zn clean                 # local generated artifacts: .zinc/compiled
zn clean --yes
zn clean sessions        # local session history, explicit only
zn clean sessions --yes
zn clean all             # local compiled artifacts + sessions
zn clean global          # global Zinc state/log files
zn clean global --yes
zn clean build           # global TurboQuant build checkout
zn clean build --yes
zn clean global all      # global state/logs + build checkout
```

Global cleanup refuses destructive removal while the recorded Zinc server is running; run `zn down` first.

## Sessions

`zn "prompt"` is an alias for `zn run "prompt"`. Both create a new session by default. Resume is explicit:

```bash
zn --continue "use the last session opened in this directory"
zn --session s115ceb70e58737f4 "resume this session id"
```

Directory-local session files live under `.zinc/sessions/`:

```text
.zinc/sessions/last                  # last opened session id for this directory
.zinc/sessions/<session-id>.jsonl     # session log
```

Each session is JSONL:

```jsonl
{"type":"session","version":1,"runtime":"zinc","id":"s...","createdAt":0}
{"type":"message","timestamp":0,"message":{"role":"user","content":"..."}}
{"type":"message","timestamp":0,"message":{"role":"assistant","content":"..."}}
```

Tool calls are recorded as `message.role = "tool"` entries containing the tool name, arguments, and result. The compiled graph controls how much of the active session log is exposed to context recovery; the default linked recovery node receives up to 65536 bytes of raw session JSONL and returns compact `recovered_context` for the assistant.

## Status

This is an early Zinc seed. It records local sessions and executes a compiled Circuitry agent leaf through a minimal OpenAI-compatible local model/tool loop.
