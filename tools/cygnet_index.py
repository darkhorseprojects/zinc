import hashlib
import pathlib
import sqlite3
import sys
import tomllib

source, output = map(pathlib.Path, sys.argv[1:])
lock = tomllib.loads((pathlib.Path(__file__).parent.parent / "models.lock").read_text())
identity = next(item["database_sha256"] for item in lock["dependency"] if item["name"] == "cygnet")
with source.open("rb") as stream:
    assert hashlib.file_digest(stream, "sha256").hexdigest() == identity, "Cygnet source checksum mismatch"
assert not output.exists(), "output exists; preserve it and choose a fresh path"
staging = output.with_name(output.name + ".building")
with staging.open("xb"):
    pass
relations = ["pertainym", "derivation", "antonym", "participle", "also", "similar", "attribute", "domain_topic", "has_domain_topic", "domain_region", "has_domain_region", "hypernym", "hyponym", "mero_part", "holo_part", "mero_substance", "holo_substance", "mero_member", "holo_member", "meronym", "holonym", "entails", "is_entailed_by", "causes", "is_caused_by", "instance_hypernym", "instance_hyponym"]
db = sqlite3.connect(staging)
try:
    db.execute("ATTACH DATABASE ? AS cygnet", (str(source),))
    db.executescript("""
    CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL) STRICT;
    CREATE TABLE concept_edges(source INTEGER NOT NULL,target INTEGER NOT NULL,PRIMARY KEY(source,target)) WITHOUT ROWID;
    CREATE TABLE form_concepts(language TEXT NOT NULL,form TEXT NOT NULL,concept INTEGER NOT NULL,PRIMARY KEY(language,form,concept)) WITHOUT ROWID;
    CREATE TABLE relations(name TEXT PRIMARY KEY);
    CREATE TABLE resources AS SELECT r.*,l.code language FROM cygnet.resources r
      LEFT JOIN cygnet.languages l ON l.rowid=r.language_rowid;
    """)
    db.executemany("INSERT INTO relations VALUES(?)", ((name,) for name in relations))
    db.executescript("""
    INSERT OR IGNORE INTO concept_edges
    SELECT r.source_rowid,r.target_rowid FROM cygnet.synset_relations r
    JOIN cygnet.relation_types t ON t.rowid=r.type_rowid
    JOIN cygnet.synsets s ON s.rowid=r.source_rowid JOIN cygnet.synsets d ON d.rowid=r.target_rowid
    WHERE t.type IN (SELECT name FROM relations) AND s.pos IN ('NOUN','VERB','ADJ','ADV') AND d.pos IN ('NOUN','VERB','ADJ','ADV') AND r.source_rowid!=r.target_rowid;
    INSERT OR IGNORE INTO concept_edges
    SELECT s.synset_rowid,d.synset_rowid FROM cygnet.sense_relations r
    JOIN cygnet.senses s ON s.rowid=r.source_rowid JOIN cygnet.senses d ON d.rowid=r.target_rowid
    JOIN cygnet.relation_types t ON t.rowid=r.type_rowid
    JOIN cygnet.synsets a ON a.rowid=s.synset_rowid JOIN cygnet.synsets b ON b.rowid=d.synset_rowid
    WHERE t.type IN (SELECT name FROM relations) AND a.pos IN ('NOUN','VERB','ADJ','ADV') AND b.pos IN ('NOUN','VERB','ADJ','ADV') AND s.synset_rowid!=d.synset_rowid;
    INSERT INTO form_concepts
    SELECT DISTINCT l.code,f.normalized_form,s.synset_rowid FROM cygnet.forms f
    JOIN cygnet.entries e ON e.rowid=f.entry_rowid JOIN cygnet.languages l ON l.rowid=e.language_rowid
    JOIN cygnet.senses s ON s.entry_rowid=e.rowid JOIN cygnet.synsets c ON c.rowid=s.synset_rowid
    WHERE e.pos IN ('NOUN','VERB','ADJ','ADV') AND c.pos IN ('NOUN','VERB','ADJ','ADV') AND f.normalized_form!='';
    CREATE INDEX form_concepts_by_concept ON form_concepts(concept,language,form);
    DROP TABLE relations;
    """)
    count = db.execute("SELECT count(*) FROM cygnet.synsets WHERE pos IN ('NOUN','VERB','ADJ','ADV')").fetchone()[0]
    assert count > 0
    db.executemany("INSERT INTO metadata VALUES(?,?)", [("format_version", "1"), ("source_identity", identity), ("recipe_identity", hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()), ("concepts", str(count))])
    db.execute("PRAGMA application_id=1514751817")
    db.execute("PRAGMA user_version=1")
    db.commit()
    db.execute("VACUUM")
finally:
    db.close()
output.hardlink_to(staging)
staging.unlink()
print(f"indexed {count} concepts")
