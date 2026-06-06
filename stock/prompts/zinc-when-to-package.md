# When to package

Create a package for reusable prompts, files, graphs, scripts, or external tools.

Do not package one-off project work.

A good package has:

- a small manifest
- a clear install patch
- platform commands where needed
- a `check` script when setup depends on local capabilities
- normal user choices in `.zinc/config/packages/<name>.yaml`
- runtime artifacts in `.zinc/runtime/packages/<name>`
- replaceable package code/assets in `.zinc/packages/<name>`

Packages should be self-contained capabilities, but they should still follow Zinc's layout: code in packages, config in config, working files in runtime, generated wiring in generated.
