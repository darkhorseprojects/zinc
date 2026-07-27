#!/usr/bin/env python3
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULES = [ROOT / "agent.md", *(ROOT / "core").glob("*.md")]
EXPECTED = {ROOT / "agent.md", ROOT / "core/run.md", ROOT / "core/database.md", ROOT / "core/env.md", ROOT / "core/builder.md"}
assert set(MODULES) == EXPECTED


def executable(path):
    result = []
    inside = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("```"):
            inside = line == "```teal" if not inside else False
        elif inside:
            result.append(line)
    return result


def structure(line):
    code = re.sub(r"'(?:\\.|[^'])*'|\"(?:\\.|[^\"])*\"", "", line.split("--", 1)[0])
    opens = len(re.findall(r"\bfunction\b", code))
    opens += len(re.findall(r"\bif\b", code)) - len(re.findall(r"\belseif\b", code))
    opens += len(re.findall(r"\b(?:for|while)\b.*\bdo\b", code))
    opens += len(re.findall(r"\brepeat\b", code))
    closes = len(re.findall(r"\bend\b", code)) + len(re.findall(r"\buntil\b", code))
    return opens - closes


def functions(path, lines):
    for start, line in enumerate(lines):
        if not re.search(r"\bfunction\b", line):
            continue
        depth = structure(line)
        if depth <= 0:
            yield start, start
            continue
        end = start
        while depth > 0:
            end += 1
            if end == len(lines):
                raise AssertionError(f"unterminated function in {path}:{start + 1}")
            depth += structure(lines[end])
        yield start, end


production = 0
for path in MODULES:
    lines = executable(path)
    production += sum(bool(line.strip()) for line in lines)
    for start, end in functions(path, lines):
        meaningful = sum(bool(line.strip()) and line.strip() not in {"end", "end,"} for line in lines[start : end + 1])
        assert meaningful <= 40, f"{path}:{start + 1} function has {meaningful} meaningful lines"
assert production < 670, f"Zinc has {production} executable Teal lines"

for path in ROOT.rglob("*"):
    if not path.is_file() or ".git" in path.parts or "__pycache__" in path.parts or path.name in {"LICENSE", "artwork.svg"}:
        continue
    if path.suffix in {".md", ".py", ".yml"} or path.name in {"VERSION", ".gitignore"}:
        lines = len(path.read_text(encoding="utf-8").splitlines())
        assert lines <= 300, f"{path} exceeds 300 lines"
print(f"Zinc executable Teal: {production} lines")
