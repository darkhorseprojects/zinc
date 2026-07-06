#!/usr/bin/env python3
import platform
import shutil
import subprocess
import sys
from pathlib import Path

import kdl


def first_arg(doc: kdl.Document, name: str) -> str:
    for node in reversed(doc.nodes):
        if node.name == name and node.args:
            value = node.args[0]
            return value if isinstance(value, str) else str(value)
    return ""


def shell_command(cmd: str) -> tuple[str, list[str], str]:
    if platform.system().lower() == "windows":
        executable = shutil.which("pwsh") or shutil.which("powershell.exe") or "powershell.exe"
        return executable, ["-NoProfile", "-Command", cmd], "powershell"
    return "sh", ["-lc", cmd], "sh"


def main() -> int:
    doc = kdl.parse(sys.stdin.read())
    cmd = first_arg(doc, "cmd")
    cwd = first_arg(doc, "cwd")

    if not cmd:
        raise SystemExit("cmd is required")
    if not cwd:
        raise SystemExit("cwd is required")
    if not Path(cwd).is_dir():
        raise SystemExit(f"cwd is not a directory: {cwd}")

    executable, args, shell_name = shell_command(cmd)
    completed = subprocess.run(
        [executable, *args],
        cwd=cwd,
        text=True,
        capture_output=True,
        check=False,
    )

    print(kdl.Document([
        kdl.Node("cmd", args=[cmd]),
        kdl.Node("output", args=[completed.stdout]),
        kdl.Node("stderr", args=[completed.stderr]),
        kdl.Node("code", args=[completed.returncode]),
        kdl.Node("shell", args=[shell_name]),
    ]), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
