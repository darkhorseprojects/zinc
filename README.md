[![Release](https://github.com/darkhorseprojects/zinc/actions/workflows/release.yml/badge.svg)](https://github.com/darkhorseprojects/zinc/actions/workflows/release.yml)
[![License](https://badgen.net/github/license/darkhorseprojects/zinc?label=License&color=black&icon=github)](LICENSE)

# Zinc

Zinc is a local Agent written in executable Markdown and Luau. It uses
[Circuitry](https://github.com/darkhorseprojects/circuitry) for execution, SQLite for durable slices, and a
Responses-compatible provider for inference.

```text
request
   ↓
current Run + recent slices + recalled slices
   ↓
provider
   ↓
Circuitry calls in native output order
   ↓
final output item is a message
```

## Files

```text
agent.md
core/database.md
core/run.md
core/env.md
core/builder.md
user.example.md
examples/run.md
```

`agent.md` exposes exactly:

```text
name
ask
read
merge
discard
```

## Configure

Editable Markdown defaults:

```text
agent.md          request_bytes  32768
core/run.md       recent_bytes    4096
core/database.md  slice_bytes    32768
core/database.md  degrees            2
```

The checked provider is llama.cpp `/v1/responses` at `http://127.0.0.1:30000` using `ternary-bonsai-27b`.

Copy `user.example.md` to your deployment as `user.md` and replace its identity value. Configure file roots,
HTTP origins, command Allow/Deny headers, shells, and explicit environment variables in `core/env.md`.

## Run

```sh
cp user.example.md user.md
printf '%s\n' '"Inspect the workspace."' | \
  deno run \
    --allow-read \
    --allow-write \
    --allow-env \
    --allow-net \
    --allow-run \
    jsr:@darkhorseprojects/circuitry/cli \
    --seal agent.md \
    --seal core \
    --seal user.md \
    --timeout 300000 \
    examples/run.md
```

Circuitry makes dangerous native modules available only to sealed code. Environment wraps filesystem, HTTP,
and process authority with editable Markdown policy. The surrounding OS account, container, or VM remains the
hard authority boundary.

## Memory

Each user request, provider response, Circuitry result/error, or merge marker is one Slice:

```text
slices(idx, run, actor, data, overflow)
trails(head, position, slice)
```

A value larger than `slice_bytes` is written exactly to an OS temporary file. The stored overflow reference
and largest valid UTF-8 tail fit `slice_bytes`. Database owns transfer and deletion.

Before every provider request Zinc takes a fresh snapshot:

```text
complete current Run
+ contiguous recent slices ≤ recent_bytes
+ Porter matches, or trigram after a Porter miss
+ configured Trail degrees with recency bias
→ complete outbound body ≤ request_bytes
```

Retrieval starts from the current request frontier. Recalled history is never fed back into the query.
Similarity means relevance, not agreement, so explicit opposing statements remain eligible. The provider
decides whether they contradict.

`request_bytes` includes only the serialized outbound request. A provider response is uncapped by Zinc, stored
as a Slice, and becomes mandatory continuation in the next request.

## Child Agents

Calling another Agent while a Run is active creates a physically separate child Database.

```luau
local run = reviewer.ask("Check the change")
local result = reviewer.read(run)
reviewer.merge(run) -- or reviewer.discard(run)
```

Merge copies slices and trails in SQL and transfers overflow ownership. Discard deletes the child Database and
its overflow files.

## Development

```sh
deno task check
deno task bench
```

Local tests use the sibling Circuitry checkout. CI checks both repositories together. Releases are created
only from semantic-version tags and are never published from `main`.

See the [wiki](https://github.com/darkhorseprojects/zinc/wiki) for Agent authoring, memory, Environment
policy, and development details.
