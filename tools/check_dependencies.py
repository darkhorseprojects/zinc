#!/usr/bin/env python3
"""Validate Zinc's pinned dependency and license metadata."""

import pathlib
import re
import tomllib
import urllib.parse
from typing import Any

from tools import check_models, install_lsqlite3, proposals

ROOT = pathlib.Path(__file__).resolve().parents[1]
SHA256 = re.compile(r"[0-9a-f]{64}")
REVISION = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?")
DOWNLOAD_SUFFIXES = (".tar.gz", ".lua", ".zip", ".db.gz")
ROCKS = {
    "dkjson": "2.10-1",
    "lsqlite3": "0.9.7-1",
    "lua-curl": "0.3.13-1",
    "luv": "1.51.0-1",
}
ROCK_LICENSES = {
    "dkjson": "MIT",
    "lsqlite3": "MIT",
    "lua-curl": "MIT",
    "luv": "Apache-2.0",
}


def validate_lock(data: dict[str, Any]) -> dict[str, dict[str, Any]]:
    if data.get("format") != 1:
        raise ValueError("dependencies.lock format must be 1")
    values = data.get("dependency")
    if not isinstance(values, list):
        raise ValueError("dependencies.lock must contain dependencies")
    dependencies: dict[str, dict[str, Any]] = {}
    for value in values:
        if not isinstance(value, dict):
            raise ValueError("dependency must be a table")
        name = value.get("name")
        if not isinstance(name, str) or not name or name in dependencies:
            raise ValueError(f"invalid or duplicate dependency name: {name}")
        for field in ("source", "expected", "license"):
            if not isinstance(value.get(field), str) or not value[field]:
                raise ValueError(f"{name} requires {field}")
        if not isinstance(value.get("version") or value.get("revision"), str):
            raise ValueError(f"{name} requires a version or revision")
        source = urllib.parse.urlparse(value["source"])
        if source.path.lower().endswith(DOWNLOAD_SUFFIXES):
            digest = value.get("sha256")
            if not isinstance(digest, str) or not SHA256.fullmatch(digest):
                raise ValueError(f"{name} requires SHA-256")
        if source.hostname == "huggingface.co" or source.path.endswith(".git"):
            revision = value.get("revision")
            if not isinstance(revision, str) or not REVISION.fullmatch(revision):
                raise ValueError(f"{name} requires a pinned revision")
        dependencies[name] = value
    return dependencies


def validate_repository(dependencies: dict[str, dict[str, Any]]) -> None:
    workflow = (ROOT / ".github/workflows/check.yml").read_text()
    readme = (ROOT / "README.md").read_text()
    entry = (ROOT / "zinc.md").read_text()
    notice = (ROOT / "NOTICE").read_text()
    rockspec = (ROOT / "zinc-dev-1.0-1.rockspec").read_text()
    rock_lock = (ROOT / "luarocks.lock").read_text()

    rockspec_dependencies = dict(re.findall(r'"([a-z0-9_-]+) == ([^"]+)"', rockspec))
    if rockspec_dependencies != {"lua": "5.5", **ROCKS}:
        raise ValueError("development rockspec dependencies are inconsistent")
    locked_dependencies = re.findall(
        r'^\s*(?:\["([a-z0-9_-]+)"\]|([a-z0-9_-]+))\s*=\s*"([^"]+)",?$',
        rock_lock,
        re.MULTILINE,
    )
    locked = {(quoted or plain): version for quoted, plain, version in locked_dependencies}
    if locked != ROCKS:
        raise ValueError("LuaRocks lock dependencies are inconsistent")
    if "make --only-deps zinc-dev-1.0-1.rockspec" not in workflow or "tools/install_lsqlite3.py" not in workflow:
        raise ValueError("workflow does not install the locked Lua dependencies")
    if "lsqlite3complete" in workflow:
        raise ValueError("workflow installs the bundled SQLite engine")
    if install_lsqlite3.URL != "https://lua.sqlite.org/home/zip/lsqlite3_v097.zip?uuid=v0.9.7":
        raise ValueError("LuaSQLite3 source is inconsistent")
    if not SHA256.fullmatch(install_lsqlite3.SHA256):
        raise ValueError("LuaSQLite3 source hash is invalid")
    for expected in ("lua-version: 5.5.0", "toolchain: 1.97.1", 'python-version: "3.12.12"'):
        if expected not in workflow:
            raise ValueError(f"workflow toolchain is inconsistent: {expected}")

    portable = dependencies["portable-agents"]
    version = portable["version"]
    if f"ref: v{version}" not in workflow or f"--version {version}" not in " ".join(portable.get("build", [])):
        raise ValueError("portable-agents versions are inconsistent")

    cygnet = dependencies["cygnet"]
    if cygnet["sha256"] != proposals.CYGNET_GZIP_SHA256:
        raise ValueError("Cygnet compressed hashes are inconsistent")
    if cygnet.get("database_sha256") != proposals.CYGNET_DATABASE_SHA256:
        raise ValueError("Cygnet database hashes are inconsistent")

    reranker = dependencies["llama-nemotron-rerank-1b-v2"]
    if not reranker["source"].endswith("/" + check_models.RERANKER):
        raise ValueError("reranker model names are inconsistent")
    if reranker["revision"] != check_models.RERANKER_REVISION:
        raise ValueError("reranker revisions are inconsistent")
    for source in (readme, entry):
        if check_models.RERANKER not in source:
            raise ValueError("documented reranker model is inconsistent")
    if check_models.RERANKER_REVISION not in readme:
        raise ValueError("documented reranker revision is inconsistent")

    chat = dependencies["LFM2.5-2.6B-GGUF"]
    if not chat["source"].endswith("/" + check_models.CHAT_MODEL):
        raise ValueError("chat model names are inconsistent")
    if chat["revision"] != check_models.CHAT_REVISION:
        raise ValueError("chat model revisions are inconsistent")
    for source in (readme, entry):
        if check_models.CHAT_MODEL not in source:
            raise ValueError("documented chat model is inconsistent")

    normalized_notice = re.sub(r"[^a-z0-9]", "", notice.lower())
    for name, license_name in ROCK_LICENSES.items():
        normalized_name = re.sub(r"[^a-z0-9]", "", name.lower())
        if normalized_name not in normalized_notice or license_name not in notice:
            raise ValueError(f"NOTICE does not cover {name}")
    for name, dependency in dependencies.items():
        normalized_name = re.sub(r"[^a-z0-9]", "", name.lower())
        if normalized_name not in normalized_notice or dependency["license"] not in notice:
            raise ValueError(f"NOTICE does not cover {name}")


def main() -> None:
    with (ROOT / "dependencies.lock").open("rb") as source:
        dependencies = validate_lock(tomllib.load(source))
    validate_repository(dependencies)


if __name__ == "__main__":
    main()
