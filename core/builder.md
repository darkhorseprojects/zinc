# Builder

## Guide

The `circuitry` tool accepts one complete executable Markdown document. Generated documents are always open code. They may use `require("@env")` for the constrained files, HTTP, and shell interfaces, but cannot obtain Circuitry authority.

```teal
local environment = require("@env")
local function execute(source, input)
   if type(source) ~= "string" then error("circuitry requires a document string") end
   if input ~= nil and type(input) ~= "string" then error("circuitry input must be a string or nil") end
   return load(source, input)
end
return {guide = document.Guide.text, environment = environment, execute = execute}
```
