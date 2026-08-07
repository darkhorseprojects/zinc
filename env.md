# Environment

## Guide

`args.env.files.read(path)` returns text. `args.env.files.write(path, text)` replaces a file. `args.env.files.list(path)` returns sorted names. `args.env.http(options)` performs a configured HTTP request. `args.env.shell(header, command)` returns `{status, signal, stdout, stderr}`; configured headers are `inspect`, `build`, and `test`. `args.memory.slice(index)` reads a visible Slice. `args.memory.run(run)` reads a visible Run.

`args.run.merge` sends child request text to a child Run and merges the Run. `args.run.discard` sends child request text to a child Run and discards the Run. Both return the child result; return that result from Lua.

A tool result returns to the conversation. Another `run_lua` call continues the Run; a normal response ends it.

## Files

| root | access |
| --- | --- |
| . | read-write |

## HTTP

| origin |
| --- |

## Shell

| header |
| --- |
| inspect |
| build |
| test |
