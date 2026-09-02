# Host

## Guide

`require("zinc.host")` returns the granted files, HTTP, and process capabilities. File operations use direct paths under the listed roots. HTTP calls use listed origins. Process calls use the canonical program and concrete arguments shown in the capability list; each call must provide positive `timeout_ms`, `stdin_bytes`, `stdout_bytes`, and `stderr_bytes` limits. Process environments are fixed by configuration. Shell authority is broad and should be used deliberately.

## Program

```lua
local document = require("pa.markdown")()
local directory = document.directory
local windows = package.config:sub(1, 1) == "\\"
local environment = windows and {
    Path = "Path",
    SystemRoot = "SystemRoot",
    TEMP = "TEMP",
    TMP = "TMP",
    USERPROFILE = "USERPROFILE",
} or {
    HOME = "HOME",
    LANG = "LANG",
    LC_ALL = "LC_ALL",
    PATH = "PATH",
    TMPDIR = "TMPDIR",
}

return require("pa.host").new({
    files = { { root = directory, access = "read-write" } },
    http = { "http://127.0.0.1:8000" },
    commands = {
        inspection = {
            program = "rg",
            arguments = { "--", "{{query}}", "{{paths...}}" },
            directory = directory,
            environment = environment,
        },
        shell = {
            program = windows and "cmd.exe" or "sh",
            arguments = windows and { "/D", "/Q" } or { "-eu" },
            directory = directory,
            environment = environment,
        },
    },
}, table.concat(document.Host.Guide, "\n\n"))
```
