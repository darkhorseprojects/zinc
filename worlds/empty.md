# Empty world

This world inherits the agent's opaque configuration, schema and fundamental interface. It requests no host operations. Its environment can contain learned Janet functions and managed state; merging changes into its origin requires the user.

`self` spawns this agent recursively. Its qualified members belong to the same scoped agent instance. Native filesystem, process and network access are disabled in the model-code worker; separately granted Imports are opaque proxies.

```janet
(def definition
  {:name "empty"

   :nested ["empty"]

   :requested []

   :operations {}

   :agent-merge false

   :document (pa/document)})
```
