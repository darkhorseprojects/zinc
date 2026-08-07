#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
files = [root / "zinc.md", root / "builder.lua", root / "format-discord.lua", *sorted((root / "src").glob("*.lua"))]
total = 0
for path in files:
    inside = path.suffix != ".md"
    count = 0
    for line in path.read_text(encoding="utf-8").splitlines():
        if path.suffix == ".md" and line.startswith("```"):
            inside = not inside and line.strip() == "```lua"
        elif inside and line.strip() and not line.lstrip().startswith("--"):
            count += 1
    total += count
    print(f"{count:4} {path.relative_to(root)}")
print(f"{total:4} total")
assert total <= 850, f"production code is {total} lines; limit is 850"
