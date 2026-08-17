#!/usr/bin/env python3
"""Validate Zinc's pinned external dependency metadata."""

import pathlib
import re
import tomllib
import urllib.parse
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[1]
SHA256 = re.compile(r"[0-9a-f]{64}")
REVISION = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?")
ARCHIVE_SUFFIXES = (".tar.gz", ".lua", ".zip", ".db.gz")


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
        if source.scheme != "https" or not source.netloc:
            raise ValueError(f"{name} requires an HTTPS source")
        if source.path.lower().endswith(ARCHIVE_SUFFIXES):
            digest = value.get("sha256")
            if not isinstance(digest, str) or not SHA256.fullmatch(digest):
                raise ValueError(f"{name} requires SHA-256")
        if source.hostname == "huggingface.co" or source.path.endswith(".git"):
            revision = value.get("revision")
            if not isinstance(revision, str) or not REVISION.fullmatch(revision):
                raise ValueError(f"{name} requires a pinned revision")
        dependencies[name] = value
    return dependencies


def main() -> None:
    with (ROOT / "dependencies.lock").open("rb") as source:
        validate_lock(tomllib.load(source))


if __name__ == "__main__":
    main()
