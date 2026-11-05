# Release notes

Workflows save JSON stage definitions, dependency results and operation outcomes. Recovery reuses completed
work and reconciles uncertain effects. Ordinary Janet scripts are not replayed after interruption; use
stages for restartable multi-operation work.

Worlds contain JSON values, not executable definitions or VM images. Temporary roots and their descendants
use RAM only. Existing binary-image databases require their original installation or fresh initialization.
