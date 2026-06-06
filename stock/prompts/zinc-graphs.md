# Zinc graphs

Zinc runs Circuitry 0.5 graphs.

Graphs are explicit: model inputs list the resources the model sees, and model tools list the tools it may call. Runtime endpoint configuration belongs in Zinc config, not graph files.

Zinc materializes `text`, `data`, `file`, `run`, and `model` resources. Circuitry owns graph validation, imports, exports, addresses, schemas, and dependency planning.

Local package installs may patch `.zinc/graphs/zinc-loop.circuitry.yaml` and import generated package resources from `.zinc/generated/packages.circuitry.yaml`.

Use `run` resources for known child graph calls. Use `run_graph` when the model dynamically needs another graph run at runtime.
