import argparse
import pathlib
import re
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
paths = [root / "package/zinc.md", *sorted((root / "package/presets").glob("*.md"))]
changed = []
with tempfile.TemporaryDirectory() as directory:
    temporary = pathlib.Path(directory)
    shutil.copy(root / "stylua.toml", temporary / "stylua.toml")
    files = []
    for path in paths:
        text = path.read_text(encoding="utf-8")
        fences = []
        for match in re.finditer(r"^```lua\n(.*?)\n```", text, re.MULTILINE | re.DOTALL):
            target = temporary / f"{path.stem}-{len(fences)}.lua"
            target.write_text(match[1] + "\n", encoding="utf-8")
            fences.append((match.start(1), match.end(1), target))
        files.append((path, text, fences))
    subprocess.run(["lx", "--lua-version", "5.5", "fmt", "--backend", "stylua", "--path", str(temporary)], check=True)
    for path, text, fences in files:
        updated = text
        for start, end, target in reversed(fences):
            formatted = target.read_text(encoding="utf-8").removesuffix("\n")
            updated = updated[:start] + formatted + updated[end:]
        if updated != text:
            changed.append(path)
            if not args.check:
                path.write_text(updated, encoding="utf-8")
if args.check and changed:
    raise SystemExit("unformatted Lua fences: " + ", ".join(str(path.relative_to(root)) for path in changed))
