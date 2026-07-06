#!/usr/bin/env python3
import json
import platform
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def parse_simple_kdl(text: str) -> dict[str, str]:
    result = {}
    try:
        tokens = shlex.split(text)
    except ValueError:
        return result

    # Standardize KDL parsing: extract cmd and cwd from the flattened tokens list.
    # Handles both single-line and multi-line KDL inputs.
    if len(tokens) >= 2 and tokens[0] == "cmd":
        result["cmd"] = tokens[1]
    if "cwd" in tokens:
        idx = tokens.index("cwd")
        if idx + 1 < len(tokens):
            result["cwd"] = tokens[idx + 1]
    return result


def load_allowlist() -> set[str] | None:
    config = HERE / "shell.kdl"
    if not config.exists():
        return None
    allowed = set()
    for line in config.read_text(encoding="utf8").splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        parts = line.split()
        if parts:
            allowed.add(parts[0])
    return allowed


def check_allowed(cmd: str, allowlist: set[str] | None) -> str | None:
    if allowlist is None:
        return "shell.kdl not found — all commands denied"
    if not cmd.strip():
        return "cmd is empty"
    try:
        tokens = shlex.split(cmd)
    except ValueError as e:
        return f"could not parse command: {e}"
    if not tokens:
        return "cmd is empty"
    head = Path(tokens[0]).name
    if head not in allowlist:
        allowed = ", ".join(sorted(allowlist)) if allowlist else "(none)"
        return f"command '{head}' is not in the allowlist. Allowed: {allowed}"
    return None


def shell_command(cmd: str) -> tuple[str, list[str], str]:
    if platform.system().lower() == "windows":
        executable = shutil.which("pwsh") or shutil.which("powershell.exe") or "powershell.exe"
        return executable, ["-NoProfile", "-Command", cmd], "powershell"
    return "sh", ["-c", cmd], "sh"


def main() -> int:
    stdin_data = sys.stdin.read()
    parsed = parse_simple_kdl(stdin_data)

    cmd = parsed.get("cmd")
    cwd = parsed.get("cwd")

    if not cmd:
        raise SystemExit("cmd is required")
    if not cwd:
        raise SystemExit("cwd is required")
    if not Path(cwd).is_dir():
        raise SystemExit(f"cwd is not a directory: {cwd}")

    allowlist = load_allowlist()
    err = check_allowed(cmd, allowlist)
    if err:
        raise SystemExit(f"shell: {err}")

    executable, args, shell_name = shell_command(cmd)
    completed = subprocess.run(
        [executable, *args],
        cwd=cwd,
        text=True,
        capture_output=True,
        check=False,
    )

    # Print output in valid KDL format directly
    print(f"cmd {json.dumps(cmd)}")
    print(f"output {json.dumps(completed.stdout)}")
    print(f"stderr {json.dumps(completed.stderr)}")
    print(f"code {completed.returncode}")
    print(f"shell {json.dumps(shell_name)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
