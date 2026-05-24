# Zinc

`zn` is a small Zig runtime for local Circuitry agent loops.

It compiles a Zinc-shaped Circuitry graph, keeps JSONL sessions, calls a local OpenAI-compatible model server, exposes graph-approved tools, and prints the assistant's final text.

## install

```bash
git clone https://github.com/darkhorseprojects/zinc.git
cd zinc
./scripts/install-linux.sh
zn-setup-turboquant
zn up
```

## use

```bash
zn "summarize this repo"
zn --continue "follow up"
zn --session <id> "resume this session"
zn compact --continue
zn validate
zn compile
zn down
```

From source:

```bash
zig build
zig build test
./zig-out/bin/zn "hello"
```

## config

Zinc reads config in this order:

```text
.zinc/config.toml
zinc.toml
~/.config/zinc/config.toml
installed defaults
```

Small default shape:

```toml
graph = "graphs/zinc-loop.circuitry.yaml"
compiled_plan = ".zinc/compiled/plan.json"
provider_base_url = "http://127.0.0.1:30000/v1"
compaction_threshold_percent = 70
compaction_graph = "graphs/zinc-compaction.circuitry.yaml"
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

[models.gemma-heretic.runtime]
tool_format = "gemma-native"
reasoning_effort = "low"
reasoning_format = "auto"
temperature = 0.5
max_tokens = 1024
tool_reasoning = false

[models.gemma-heretic.runtime.budgets]
off = 0
low = 256
medium = 1024
high = 4096
extra-high = -1
```

Reasoning is one compiled value: `reasoning_tokens`.

```text
0   thinking off
>0  thinking on, bounded to that many tokens
-1  thinking on, no request budget cap
```

`reasoning_format` is only extraction. Use `auto` unless you intentionally want raw thought markers in visible output.

## graphs

Default graph:

```text
graphs/zinc-loop.circuitry.yaml
  links graphs/zinc-context-recovery.circuitry.yaml
```

Runtime path:

```text
session JSONL -> deterministic context assembly
assembled context + user turn + session_dir -> focused_recovery graph agent with tools
assembled context + focused_recovery output + user turn -> assistant -> final text
```

The raw JSONL session log is parsed by Zinc runtime code. It is not passed to the assistant or focused recovery agent. The focused recovery agent receives only assembled context, current user turn, and the session directory, then uses graph-declared tools such as `bash`/`read` if it wants archive context. Text resources with prompt-pack frontmatter are listed to the assistant by stable id and can be lazy-loaded through `read {"path":"prompt:<id>"}`; no local prompt file paths are exposed. The compaction command is the intentional exception: `zn compact` gives a session log to the compaction graph agent so it can produce a durable summary. Zinc also runs that graph automatically when the estimated session log token count reaches `compaction_threshold_percent` of the configured model `fit_ctx`; set the percentage to `0` to disable automatic compaction.

Compaction path:

```text
zn compact --continue
  uses graphs/zinc-compaction.circuitry.yaml
  appends a compaction summary to the session log
```

Run another graph once:

```bash
zn graphs/custom.circuitry.yaml "do the thing"
zn graphs/custom.circuitry.yaml --input brief=hello
zn graphs/custom.circuitry.yaml --inputs-json '{"brief":"hello"}'
```

## sessions

Project sessions live in:

```text
.zinc/sessions/last
.zinc/sessions/<session-id>.jsonl
```

Conversation messages, runtime events, and compaction summaries are JSONL entries. Continuation replays exact first messages, the latest compaction summary when available, the exact transcript tail after that compaction, and focused matches from other session files.

## tools

Graphs choose tool names. Zinc validates them at compile time and exposes only that list at runtime.

Builtins:

```text
read
write
edit
bash
request_circuitry_run
```

## source map

```text
src/main.zig       CLI dispatch
src/commands.zig   validate, compile, run
src/engine.zig     agent loop
src/provider.zig   OpenAI-compatible HTTP
src/plan.zig       compiled plan loading
src/server.zig     zn up/down
src/config.zig     config lookup
src/session.zig    JSONL sessions
src/tools.zig      builtin tools
src/graph.zig      Circuitry subset
```
