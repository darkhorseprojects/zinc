import argparse
import pathlib
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
    for index, path in enumerate(paths):
        text = path.read_text()
        start = text.index("```lua\n") + len("```lua\n")
        end = text.index("\n```", start)
        target = temporary / f"{index}.lua"
        target.write_text(text[start:end] + "\n")
        files.append((path, text, start, end, target))
    subprocess.run(["lx", "--lua-version", "5.5", "fmt", "--backend", "stylua", "--path", str(temporary)], check=True)
    for path, text, start, end, target in files:
        formatted = target.read_text().removesuffix("\n")
        updated = text[:start] + formatted + text[end:]
        if updated != text:
            changed.append(path)
            if not args.check:
                path.write_text(updated)
if args.check and changed:
    raise SystemExit("unformatted Lua fences: " + ", ".join(str(path.relative_to(root)) for path in changed))
