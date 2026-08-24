# Host

## Guide

Use `require("host")` to load this capability. `host.files.read { path, offset, limit }` reads configured UTF-8 files; omit `offset` and `limit` to read the complete file. `host.files.edit { path, edits }` applies unique, non-overlapping exact replacements. `host.files.write { path, content }` atomically creates or replaces a file.

`host.http { url, method, headers, body }` contacts only configured origins.

`host.run { name, values, input }` executes one configured program with an argument vector. Values replace exact `{{name}}` arguments, while `{{name...}}` expands an array. No shell interprets the values.

## Files

| root | access |
|---|---|
| . | read-write |

## HTTP

| origin |
|---|

## Variables

| name |
|---|
| HOME |
| PATH |
| TMPDIR |
| TEMP |
| TMP |
| SYSTEMROOT |

## Commands

| name | program | arguments | directory |
|---|---|---|---|
| inspect | rg | ["--","{{query}}","{{paths...}}"] | . |
| test | moon | ["run","test"] | . |

## Program

```lua
require("src.dependencies").activate(package.directory)
return require("src.host").new(document.Host)
```
