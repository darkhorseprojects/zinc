import gzip
import hashlib
import json
import pathlib
import shutil
import sqlite3
import tomllib
import urllib.request
from contextlib import closing

root = pathlib.Path(__file__).resolve().parent.parent
lock = tomllib.loads((root / "models.lock").read_text())
cygnet, stops = (next(item for item in lock["dependency"] if item["name"] == name) for name in ("cygnet", "stopwords-iso"))
stopwords = root / "data/stopwords-iso.json"
assert hashlib.sha256(stopwords.read_bytes()).hexdigest() == stops["sha256"], "stopword checksum mismatch"
assert json.loads(stopwords.read_text())["en"], "missing English stopwords"
recipe = hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()
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
    staging = index.with_suffix(".building")
    with staging.open("xb"):
        pass
    with closing(sqlite3.connect(staging)) as db:
        db.execute("ATTACH DATABASE ? AS cygnet", (str(source),))
        db.executescript("""
        CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL) STRICT;
        CREATE TABLE concept_edges(source INTEGER NOT NULL,target INTEGER NOT NULL,PRIMARY KEY(source,target)) WITHOUT ROWID;
        CREATE TABLE form_concepts(language TEXT NOT NULL,form TEXT NOT NULL,concept INTEGER NOT NULL,PRIMARY KEY(language,form,concept)) WITHOUT ROWID;
        CREATE TEMP TABLE relations(name TEXT PRIMARY KEY);
        CREATE TABLE resources AS SELECT r.*,l.code language FROM cygnet.resources r
          LEFT JOIN cygnet.languages l ON l.rowid=r.language_rowid;
        """)
        relations = ["pertainym", "derivation", "antonym", "participle", "also", "similar", "attribute", "domain_topic", "has_domain_topic", "domain_region", "has_domain_region", "hypernym", "hyponym", "mero_part", "holo_part", "mero_substance", "holo_substance", "mero_member", "holo_member", "meronym", "holonym", "entails", "is_entailed_by", "causes", "is_caused_by", "instance_hypernym", "instance_hyponym"]
        db.executemany("INSERT INTO relations VALUES(?)", ((name,) for name in relations))
        db.executescript("""
        INSERT OR IGNORE INTO concept_edges
        WITH edges(source,target,type) AS (
          SELECT r.source_rowid,r.target_rowid,t.type FROM cygnet.synset_relations r
          JOIN cygnet.relation_types t ON t.rowid=r.type_rowid UNION ALL
          SELECT s.synset_rowid,d.synset_rowid,t.type FROM cygnet.sense_relations r
          JOIN cygnet.senses s ON s.rowid=r.source_rowid JOIN cygnet.senses d ON d.rowid=r.target_rowid
          JOIN cygnet.relation_types t ON t.rowid=r.type_rowid
        ) SELECT e.source,e.target FROM edges e
        JOIN cygnet.synsets s ON s.rowid=e.source JOIN cygnet.synsets d ON d.rowid=e.target
        WHERE e.type IN relations AND s.pos IN ('NOUN','VERB','ADJ','ADV') AND d.pos IN ('NOUN','VERB','ADJ','ADV') AND e.source!=e.target;
        INSERT INTO form_concepts
        SELECT DISTINCT l.code,f.normalized_form,s.synset_rowid FROM cygnet.forms f
        JOIN cygnet.entries e ON e.rowid=f.entry_rowid JOIN cygnet.languages l ON l.rowid=e.language_rowid
        JOIN cygnet.senses s ON s.entry_rowid=e.rowid JOIN cygnet.synsets c ON c.rowid=s.synset_rowid
        WHERE e.pos IN ('NOUN','VERB','ADJ','ADV') AND c.pos IN ('NOUN','VERB','ADJ','ADV') AND f.normalized_form!='';
        CREATE INDEX form_concepts_by_concept ON form_concepts(concept,language,form);
        """)
        count = db.execute("SELECT count(*) FROM cygnet.synsets WHERE pos IN ('NOUN','VERB','ADJ','ADV')").fetchone()[0]
        assert count > 0
        db.executemany("INSERT INTO metadata VALUES(?,?)", [("format_version", str(cygnet["generated_format"])), ("source_identity", cygnet["database_sha256"]), ("recipe_identity", recipe), ("concepts", str(count))])
        db.execute("PRAGMA application_id=1514751817")
        db.execute("PRAGMA user_version=1")
        db.commit()
        db.execute("VACUUM")
    index.hardlink_to(staging)
    staging.unlink()
with closing(sqlite3.connect(f"file:{index.as_posix()}?mode=ro", uri=True)) as db:
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
staged = assets / "cygnet.db.building"
staged.hardlink_to(index)
staged.replace(assets / "cygnet.db")
shutil.copyfile(stopwords, assets / "stopwords.json")
(assets / "cygnet.NOTICE.json").write_text(json.dumps({"source": cygnet, "recipe": recipe, "resources": resources}, ensure_ascii=False, indent=2) + "\n")
print(assets)
