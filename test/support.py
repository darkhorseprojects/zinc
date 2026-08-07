import json
import os
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
AGENT = pathlib.Path(os.environ.get("AGENT", ROOT.parent / "portable-agents/target/release/agent")).resolve()
LUA_SHARE = pathlib.Path.home() / ".local/share/lua/5.5"
LUA_LIB = pathlib.Path.home() / ".local/lib/lua/5.5"


class Package:
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zinc-test-")
        self.root = pathlib.Path(self.temporary.name)
        self.package = self.root / "zinc"
        self.home = self.root / "home"
        self.work = self.root / "work"
        shutil.copytree(ROOT, self.package, ignore=shutil.ignore_patterns(".git", "__pycache__", "*.sqlite3*"))
        self.home.mkdir()
        self.work.mkdir()
        self.environment = os.environ.copy()
        self.environment.update({
            "HOME": str(self.home),
            "USERPROFILE": str(self.home),
            "PATH": str(pathlib.Path.home() / ".local/bin") + os.pathsep + os.environ["PATH"],
            "LUA_PATH": f"{LUA_SHARE}/?.lua;{LUA_SHARE}/?/init.lua;;",
            "LUA_CPATH": f"{LUA_LIB}/?.so;;",
        })

    def close(self):
        self.temporary.cleanup()

    def run(self, entry, *, input=b"", arguments=(), authority=(), timeout=30, deadline=None):
        command = [str(AGENT), "run", "--directory", str(self.package), "--entry", entry]
        for module in authority:
            command += ["--authority", module]
        if deadline:
            command += ["--timeout", deadline]
        if arguments:
            command += ["--", *arguments]
        return subprocess.run(command, input=input, cwd=self.work, env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=False)

    def lua(self, source, authority=(), timeout=30, deadline=None):
        entry = "_test.lua"
        (self.package / entry).write_text("local json=require('dkjson')\nlocal value=(function()\n" + source + "\nend)()\nreturn assert(json.encode(value))\n", encoding="utf-8")
        result = self.run(entry, authority=(entry, *authority), timeout=timeout, deadline=deadline)
        if result.returncode:
            raise AssertionError(result.stderr.decode())
        return json.loads(result.stdout)


def success(result):
    if result.returncode:
        raise AssertionError(result.stderr.decode())
    return result
