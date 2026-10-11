# Local fixture benchmark

Command: `python3 tools/benchmark.py 3`.

Linux, Janet 1.42.1, SQLite 3.53.4, actual PA subprocesses, bubblewrap workers, fresh Git packages and SQLite databases, local synthetic HTTP provider. Every repetition ran the complete integration assertions, including JSON/SSE recursion, unknown usage, dedup, cancellation, worlds, code activation/rollback, original-source summaries and observer SIGKILL survival.

| Measurement | Seconds |
|---|---:|
| Runs | 9.777, 10.108, 10.508 |
| p50 | 10.108 |
| p95 | 10.508 |

This measures regression-fixture wall time, including package setup and process startup. It is not a live-model token-throughput benchmark, Discord latency measurement, or comparison against the old Lua implementation.

Formatted structural gate: `agent.janet` 576 lines versus original 724 (20.4% reduction); `store.janet` 468 versus original 586 (20.1%). No feature removal or line compression was used to meet the limits.
