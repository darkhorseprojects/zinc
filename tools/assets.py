import gzip
import hashlib
import json
import pathlib
import shutil
import sqlite3
import subprocess
import sys
import tomllib
import urllib.request

root = pathlib.Path(__file__).resolve().parent.parent
lock = tomllib.loads((root / "models.lock").read_text())
cygnet, stops = (next(item for item in lock["dependency"] if item["name"] == name) for name in ("cygnet", "stopwords-iso"))
stopwords = root / "data/stopwords-iso.json"
assert hashlib.sha256(stopwords.read_bytes()).hexdigest() == stops["sha256"], "stopword checksum mismatch"
assert json.loads(stopwords.read_text())["en"], "missing English stopwords"
recipe = hashlib.sha256((root / "tools/cygnet_index.py").read_bytes()).hexdigest()
key = hashlib.sha256(json.dumps([cygnet["database_sha256"], recipe, cygnet["generated_format"]]).encode()).hexdigest()
cache = root / "build/resources"
cache.mkdir(parents=True, exist_ok=True)
archive = cache / "cygnet.db.gz"
if not archive.exists():
    urllib.request.urlretrieve(cygnet["source"], archive)
with archive.open("rb") as stream:
    assert hashlib.file_digest(stream, "sha256").hexdigest() == cygnet["sha256"], "Cygnet archive checksum mismatch"
source = cache / "cygnet.db"
if not source.exists():
    with gzip.open(archive, "rb") as stream, source.open("xb") as output:
        shutil.copyfileobj(stream, output)
with source.open("rb") as stream:
    assert hashlib.file_digest(stream, "sha256").hexdigest() == cygnet["database_sha256"], "Cygnet database checksum mismatch"
directory = cache / key
directory.mkdir(exist_ok=True)
index = directory / "cygnet.db"
if not index.exists():
    subprocess.run([sys.executable, str(root / "tools/cygnet_index.py"), str(source), str(index)], check=True)
with sqlite3.connect(f"file:{index.as_posix()}?mode=ro", uri=True) as db:
    assert db.execute("PRAGMA quick_check").fetchone() == ("ok",), "corrupt Cygnet index"
    metadata = dict(db.execute("SELECT key,value FROM metadata"))
    assert metadata["format_version"] == str(cygnet["generated_format"])
    assert metadata["source_identity"] == cygnet["database_sha256"] and metadata["recipe_identity"] == recipe
    assert {row[0] for row in db.execute("SELECT name FROM sqlite_schema WHERE type='table'")} == {"metadata", "concept_edges", "form_concepts", "resources"}
    db.row_factory = sqlite3.Row
    resources = [dict(row) for row in db.execute("SELECT * FROM resources ORDER BY code")]
    assert resources and all(item["code"] and item["licence"] for item in resources), "missing resource attribution"
assets = root / "build/assets"
assets.mkdir(exist_ok=True)
shutil.copyfile(index, assets / "cygnet.db")
shutil.copyfile(stopwords, assets / "stopwords.json")
(assets / "cygnet.NOTICE.json").write_text(json.dumps({"source": cygnet, "recipe": recipe, "resources": resources}, ensure_ascii=False, indent=2) + "\n")
print(assets)
