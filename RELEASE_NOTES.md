# Zinc 0.2.0

- World source follows top-level definitions, redefinitions and nil removal.
- Parallel tool calls fork a shared source/history snapshot into independent branches.
- Every model round records its exact request, current source and memory windows.
- Trusted `views` and `render` exports inspect saved prompts without recomputation.
- Rerank scores remain inspectable without rendering model bookkeeping.
- Native filesystem access is forbidden by default; save remains an explicit grant.
- Structured diagnostics preserve detail across matching PA protocol-3 boundaries.
- Stopwords, resource provenance and the Cygnet builder install with package sources.
- Tests and embedded CI fixtures are removed; six-platform build CI remains.

Database schema version is 1. Preserve incompatible stores and provision a fresh
path; there is no migration or compatibility execution path.
