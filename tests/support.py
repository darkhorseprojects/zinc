import json
import os
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
AGENT = pathlib.Path(os.environ.get("AGENT", ROOT.parent / "portable-agents/zig-out/bin/agent")).resolve()
LUA_SHARE = pathlib.Path.home() / ".local/share/lua/5.5"
LUA_LIB = pathlib.Path.home() / ".local/lib/lua/5.5"
LUA_EXTENSION = "dll" if os.name == "nt" else "so"


class Package:
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zinc-test-")
        self.root = pathlib.Path(self.temporary.name)
        self.package = self.root / "zinc"
        self.home = self.root / "home"
        self.work = self.root / "work"
        shutil.copytree(
            ROOT,
            self.package,
            ignore=shutil.ignore_patterns(".git", ".venv*", "__pycache__", "*.sqlite3*"),
        )
        self.home.mkdir()
        self.work.mkdir()
        self.environment = os.environ.copy()
        self.environment.update({
            "HOME": str(self.home),
            "USERPROFILE": str(self.home),
            "PATH": str(pathlib.Path.home() / ".local/bin") + os.pathsep + os.environ["PATH"],
            "LUA_PATH_5_5": f"{LUA_SHARE}/?.lua;{LUA_SHARE}/?/init.lua;;",
            "LUA_CPATH_5_5": f"{LUA_LIB}/?.{LUA_EXTENSION};;",
        })

    def close(self):
        self.temporary.cleanup()

    def run(self, entry, *, input=b"", arguments=(), trusted=(), mounts=None, timeout=30, deadline="30s"):
        command = [str(AGENT), "run", "--directory", str(self.package), "--entry", entry]
        if mounts:
            for name, path in mounts.items():
                command += ["--mount", f"{name}={path}"]
        if trusted:
            for name in trusted:
                command += ["--trust", name]
        command += ["--lua-memory", "96MiB", "--timeout", deadline]
        if arguments:
            command += ["--", *arguments]
        return subprocess.run(command, input=input, cwd=self.work, env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=False)

    def lua(self, source, trusted=(), timeout=30, deadline="30s"):
        entry = "_test.lua"
        (self.package / "_json.lua").write_text("return require('dkjson')\n", encoding="utf-8")
        (self.package / entry).write_text("local json=require('dkjson')\nlocal value=(function()\n" + source + "\nend)()\ncoroutine.yield(assert(json.encode(value)))\n", encoding="utf-8")
        result = self.run(entry, mounts={"dkjson": "_json.lua"}, trusted=("dkjson", "_test", *trusted), timeout=timeout, deadline=deadline)
        if result.returncode:
            raise AssertionError(result.stderr.decode())
        return json.loads(result.stdout)

    def lua_stream(self, source, trusted=(), timeout=30, deadline="30s"):
        entry = "_stream.lua"
        (self.package / "_json.lua").write_text("return require('dkjson')\n", encoding="utf-8")
        (self.package / entry).write_text(source, encoding="utf-8")
        result = self.run(entry, mounts={"dkjson": "_json.lua"}, trusted=("dkjson", "_stream", *trusted), timeout=timeout, deadline=deadline)
        if result.returncode:
            raise AssertionError(result.stderr.decode())
        return [json.loads(line) for line in result.stdout.splitlines()]


def success(result):
    if result.returncode:
        raise AssertionError(result.stderr.decode())
    return result
