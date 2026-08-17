#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
AGENT = os.environ.get("AGENT", str(ROOT.parent / "portable-agents" / "target" / "debug" / ("agent.exe" if os.name == "nt" else "agent")))
LUA_FILES = sorted(ROOT.glob("src/**/*.lua"))
MARKDOWN_FILES = [ROOT / "zinc.md"]


def run(*command: str) -> None:
    subprocess.run(command, cwd=ROOT, check=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", action="store_true")
    arguments = parser.parse_args()

    run(sys.executable, "-m", "tools.check_dependencies")
    run("stylua", "--check", *(str(path.relative_to(ROOT)) for path in LUA_FILES))
    for path in LUA_FILES:
        source = f"assert(loadfile({json.dumps(str(path))}))"
        run("lua", "-e", source)
    for entry in MARKDOWN_FILES:
        run(
            AGENT, "check", "--directory", str(ROOT), "--entry", entry.name,
            "--register", "host=host.md", "design=design.md",
            "--authorize", "src.host", "src.models", "src.store",
            "--memory", "96MiB", "--timeout", "30s",
        )

    test_python = os.environ.get("ZINC_TEST_PYTHON", sys.executable)
    command = [test_python, "-m", "pytest", "-q"]
    if arguments.models:
        command += ["-m", "model"]
    else:
        command += ["-m", "not model"]
    run(*command)


if __name__ == "__main__":
    main()
