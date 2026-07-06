#!/usr/bin/env python3
"""Install Zinc's CLI/web assets and create the editable Zinc home."""

import os
import shutil
import subprocess
import sys
from pathlib import Path

AGENT_FILES = ["turn.md", "openai-responses.py", "openai-responses.kdl", "shell.py", "requirements.txt"]


def require(command: str) -> str:
    path = shutil.which(command)
    if not path:
        raise SystemExit(f"Error: '{command}' was not found on PATH.")
    return path


def default_zinc_home() -> Path:
    if os.environ.get("ZINC_HOME"):
        return Path(os.environ["ZINC_HOME"]).expanduser()
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "Zinc"
    if sys.platform.startswith("win"):
        return Path(os.environ.get("APPDATA", Path.home())) / "Zinc"
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "zinc"


def copy_executable(src: Path, dst: Path):
    shutil.copy(src, dst)
    dst.chmod(0o755)


def agent_python(agent_dir: Path) -> Path:
    return agent_dir / (".venv/Scripts/python.exe" if sys.platform.startswith("win") else ".venv/bin/python")


def default_config(zinc_dir: Path, agent_dir: Path, web_dir: Path) -> str:
    return f'''store "{zinc_dir / "zinc.db"}"
turn "{agent_dir / "turn.md"}"
zinc-dir "{zinc_dir}"
agent-dir "{agent_dir}"
python "{agent_python(agent_dir)}"
raw-context-bytes 8192
packet-overflow-bytes 65536
'''


def sync_agent_templates(agent_src: Path, agent_dir: Path):
    agent_dir.mkdir(parents=True, exist_ok=True)
    for name in AGENT_FILES:
        src = agent_src / name
        dst = agent_dir / name
        if src.exists() and not dst.exists():
            copy_executable(src, dst) if name.endswith(".py") else shutil.copy(src, dst)


def install_agent_deps(agent_dir: Path) -> Path:
    requirements = agent_dir / "requirements.txt"
    if not requirements.exists():
        raise SystemExit(f"requirements not found: {requirements}")

    venv = agent_dir / ".venv"
    uv = shutil.which("uv")
    if uv:
        subprocess.run([uv, "venv", str(venv)], check=True)
    else:
        subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True)

    python = venv / ("Scripts/python.exe" if sys.platform.startswith("win") else "bin/python")
    if uv:
        subprocess.run([uv, "pip", "install", "--python", str(python), "-r", str(requirements)], check=True)
    else:
        subprocess.run([str(python), "-m", "pip", "install", "-r", str(requirements)], check=True)
    for name in ["openai-responses.py", "shell.py"]:
        path = agent_dir / name
        if not path.exists():
            raise SystemExit(f"agent source process not found: {path}")
        text = path.read_text(encoding="utf8")
        body = "\n".join(text.splitlines()[1:]) + "\n" if text.startswith("#!") else text
        path.write_text(f"#!{python}\n{body}", encoding="utf8")
        path.chmod(0o755)
    return python


def write_text_if_missing(path: Path, text: str):
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def main():
    bun = require("bun")

    script_dir = Path(__file__).resolve().parent
    project_root = script_dir.parent
    agent_src = project_root / "agent"
    web_src = project_root / "web"
    zn_src = script_dir / "zn"

    install_dir = Path(os.environ.get("ZINC_INSTALL_DIR", Path.home() / ".local" / "lib" / "zinc")).expanduser().resolve()
    bin_dir = Path(os.environ.get("ZINC_BIN_DIR", Path.home() / ".local" / "bin")).expanduser().resolve()
    zinc_dir = default_zinc_home().resolve()
    agent_dir = zinc_dir / "agent"

    print(f"Installing Zinc package files to {install_dir}")
    print(f"Creating editable Zinc home at {zinc_dir}")
    install_dir.mkdir(parents=True, exist_ok=True)
    bin_dir.mkdir(parents=True, exist_ok=True)
    zinc_dir.mkdir(parents=True, exist_ok=True)

    web_dist = web_src / "dist" / "server" / "index.js"
    if not web_dist.exists():
        if not (web_src / "src").exists():
            raise SystemExit(f"built web server not found: {web_dist}")
        subprocess.run([bun, "install"], cwd=web_src, check=True)
        subprocess.run([bun, "run", "build"], cwd=web_src, check=True)

    web_dest = install_dir / "web"
    if web_dest.exists():
        shutil.rmtree(web_dest)
    shutil.copytree(web_src, web_dest, ignore=shutil.ignore_patterns("node_modules", ".git", ".vitest"))

    agent_templates_dest = install_dir / "agent"
    if agent_templates_dest.exists():
        shutil.rmtree(agent_templates_dest)
    shutil.copytree(agent_src, agent_templates_dest, ignore=shutil.ignore_patterns("__pycache__", ".venv"))

    zn_bin_dir = install_dir / "bin"
    zn_bin_dir.mkdir(parents=True, exist_ok=True)
    zn_dest = zn_bin_dir / "zn"
    copy_executable(zn_src, zn_dest)
    wrapper = bin_dir / "zn"
    wrapper.write_text(f'#!/bin/sh\nexec "{zn_dest}" "$@"\n')
    wrapper.chmod(0o755)

    sync_agent_templates(agent_src, agent_dir)
    write_text_if_missing(zinc_dir / "config.kdl", default_config(zinc_dir, agent_dir, web_dest))
    python = install_agent_deps(agent_dir)

    print(f"Installed zn to {wrapper}")
    print(f"Editable agent files are in {agent_dir}")
    print(f"Default source-process Python: {python}")


if __name__ == "__main__":
    main()
