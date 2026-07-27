import json
import os
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CIRCUITRY = pathlib.Path(os.environ.get("CIRCUITRY", ROOT.parent / "circuitry/zig-out/bin/circuitry")).resolve()


class Zinc:
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zinc-test-")
        self.root = pathlib.Path(self.temporary.name)
        self.home = self.root / "home"
        self.work = self.root / "work"
        self.home.mkdir()
        self.work.mkdir()
        self.environment = os.environ.copy()
        self.environment["HOME"] = str(self.home)
        installed = self.invoke("agent", "install", "zinc", ROOT)
        if installed.returncode:
            raise AssertionError(installed.stderr.decode())
        self.agent = self.home / ".agents/agents/zinc"
        self.state = self.agent / "state"
        self.user("local-operator")

    def close(self):
        self.temporary.cleanup()

    def user(self, username, text=""):
        self.state.joinpath("user.md").write_text(
            f"# User\n\n| field | value |\n| --- | --- |\n| username | {username} |\n\n{text}",
            encoding="utf-8",
        )

    def invoke(self, *arguments, input=b"", cwd=None):
        result = subprocess.run(
            [CIRCUITRY, *map(str, arguments)],
            input=input,
            cwd=cwd or self.work,
            env=self.environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
            check=False,
        )
        return result

    def execute(self, source, input=b"", arguments=()):
        entry = self.work / "test-entry.lua"
        entry.write_text(source, encoding="utf-8")
        result = self.invoke(
            "run",
            "--root", self.agent,
            "--seal", self.agent,
            "--seal", entry,
            entry,
            "--",
            *arguments,
            input=input,
        )
        if result.returncode:
            raise AssertionError(result.stderr.decode())
        return result.stdout

    def value(self, source):
        wrapped = "local json=require('@authority'):require('dkjson'); local value=(function()\n" + source + "\nend)(); return assert(json.encode(value))"
        return json.loads(self.execute(wrapped))

    @property
    def database(self):
        return self.state / "database.sqlite3"


def check(result):
    if result.returncode:
        raise AssertionError(result.stderr.decode())
    return result
