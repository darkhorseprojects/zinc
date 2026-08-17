#!/usr/bin/env python3
"""Build the pinned LuaSQLite3 binding against the system SQLite library."""

import hashlib
import io
import pathlib
import subprocess
import tempfile
import urllib.request
import zipfile

URL = "https://lua.sqlite.org/home/zip/lsqlite3_v097.zip?uuid=v0.9.7"
SHA256 = "de690611e248daceebe85ffeca99899a0fbdac92b91bd7ede11dac66eb290a9a"
ROOT = pathlib.PurePosixPath("lsqlite3_v097")
ROCKSPEC = ROOT / "lsqlite3-0.9.7-1.rockspec"


def main() -> None:
    request = urllib.request.Request(URL, headers={"User-Agent": "Zinc dependency installer/1"})
    with urllib.request.urlopen(request, timeout=60) as response:
        archive = response.read()
    if hashlib.sha256(archive).hexdigest() != SHA256:
        raise RuntimeError("LuaSQLite3 source archive SHA-256 mismatch")

    with zipfile.ZipFile(io.BytesIO(archive)) as source, tempfile.TemporaryDirectory(prefix="zinc-lsqlite3-") as temporary:
        names = [pathlib.PurePosixPath(name) for name in source.namelist()]
        if ROCKSPEC not in names or any(path.is_absolute() or ".." in path.parts for path in names):
            raise RuntimeError("LuaSQLite3 source archive layout is invalid")
        source.extractall(temporary)
        directory = pathlib.Path(temporary, *ROOT.parts)
        subprocess.run(
            ["luarocks", "--lua-version=5.5", "make", ROCKSPEC.name],
            cwd=directory,
            check=True,
        )


if __name__ == "__main__":
    main()
