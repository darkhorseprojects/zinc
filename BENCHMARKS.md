# Benchmark plan

This plan evaluates Zinc as a memory backend, not as a substitute benchmark harness. Published comparisons are valid only when the dataset, reader/task model, judge, prompts, context limit, and scorer match the official run.

## Correction

LongMemEval-V2 publishes `small` and `medium` tiers. It does not publish a `large` tier. `medium` is its largest public tier, with question-specific haystacks of up to 500 trajectories and 115M tokens. Zinc will run the official `medium` tier. A result will not be labeled `large`. If “large” means the original LongMemEval benchmark rather than LongMemEval-V2, that is a separate experiment.

Sources:

- https://github.com/JJerryJi/LongMemEval-V2
- https://huggingface.co/datasets/xiaowu0162/longmemeval-v2
- https://memoryarena.github.io/
- https://arxiv.org/abs/2602.16313

## Shared protocol

1. Pin the benchmark repository commit, dataset revision and checksums, model revisions, prompts, judge, and Zinc/Portable Agents commits.
2. Implement adapters outside `package/`. The release package and benchmark-specific code remain distinct.
3. Give every benchmark episode or conversation a fresh actor and Store. Never retrieve across examples.
4. Insert records in their original order. Preserve session boundaries, timestamps, roles, tool actions, observations, and benchmark IDs in the inserted text. Do not summarize during ingestion.
5. Use Zinc’s released Cygnet grounding, FTS retrieval, Nemotron reranker, and fixed retrieval limits without test-set tuning.
6. Use the official reader or task-agent model for comparable runs. Report Zinc’s native LFM reader separately and never compare it directly with results using another backbone.
7. Run the official scorer unchanged. Timeouts, parser failures, missing answers, and environment failures remain failures in the denominator.
8. Save every input ID, retrieved context, answer/action trace, raw score, error, latency, token count, Store size, peak RSS, model revision, and command line.
9. Report complete denominators and per-category results, not only an aggregate. Include 95% paired bootstrap intervals where the benchmark does not supply uncertainty.
10. Publish a manifest and raw outputs. Label smoke tests and partial runs as such; they are not benchmark scores.

The adapter lifecycle is:

```text
Insert(record) -> append a durable event
Query(question) -> run Zinc retrieval at the final inserted event
Update(trace) -> append the completed session trace
Destroy() -> remove the isolated Store
```

The adapter will use Zinc’s Store and retrieval modules directly from a copied release closure. It will not simulate ingestion by asking the chat model to “remember” every record.

## LongMemEval-V2

Use the official `Memory.insert(trajectory)` and `Memory.query(query, query_image)` interface and official `evaluation/harness.py`.

### Run

- Tier: `medium`.
- Domains: `web` and `enterprise`.
- Questions: every released medium-tier question accepted by the official validator.
- Reader: the official fixed reader configuration, currently Qwen3.5-9B in the released instructions.
- Context limit: the official `--memory-context-max-tokens` value, unchanged across methods.
- Judge and metrics: official answer accuracy, query latency, aggregate metrics, and LAFS packaging.
- Zinc query output: one non-empty text context item containing retrieved chronological and semantic records. Zinc currently returns no image context; report the method as text-only.

### Report

Report web, enterprise, combined, and each of the five abilities: static state recall, dynamic state tracking, workflow knowledge, environment gotchas, and premise awareness. Include insertion wall time, cold and warm query latency, p50/p95 latency, peak RSS, Store bytes, retrieved tokens, reader tokens, judge cost, failures, and official LAFS fields.

Do not compare Zinc’s text-only run with a multimodal method without marking that capability difference.

## MemoryArena

MemoryArena is an interactive Memory-Agent-Environment benchmark, not a static question-answer dataset. A conversion that merely predicts the released `answers` field is not a valid MemoryArena run.

### Prerequisite

Pin an official runnable environment/harness revision for the paper. The public dataset alone is insufficient for comparable bundled-shopping and environment-action results. If no official runnable harness is available, publish only an adapter validation and state that no MemoryArena score was produced.

### Run

- Use every official test task in bundled shopping, group travel planning, progressive search, formal-reasoning math, and formal-reasoning physics.
- Start with an empty Store per task group.
- Before each action, retrieve memory from completed prior sessions plus the active session trace.
- After each subtask, append the complete action/observation trace through `Update`.
- Match the paper’s task-agent model and environment settings for the comparable run. Run Zinc’s LFM model only as a separately labeled configuration.
- Preserve the official action budget, termination rules, environment state, and graders.

### Report

Use official Task Success Rate (SR), Task Progress Score (PS), group-travel soft Process Score (sPS), and depth-wise success where available. Report each domain separately, exact task counts, action steps, retrieved tokens per action, total model tokens per task, wall time, environment failures, and peak Store size.

Never call the Hugging Face dataset export an end-to-end MemoryArena result.

## Comparison table

For each benchmark, publish matched rows for:

- official no-memory or no-retrieval baseline;
- official lexical/vector baseline where available;
- Zinc with the matched official reader/task model;
- Zinc with its native LFM model, labeled non-comparable.

Do not copy published baseline numbers into a table beside a new Zinc run unless the protocol is identical. Re-run matched baselines in the same environment whenever feasible.
