import gzip
import hashlib
import pathlib
import sqlite3
import tempfile

from tools import proposals


def source(root):
    database = root / "cygnet.db"
    connection = sqlite3.connect(database)
    connection.executescript("""
CREATE TABLE languages(rowid INTEGER PRIMARY KEY,code TEXT NOT NULL,name TEXT);
CREATE TABLE entries(rowid INTEGER PRIMARY KEY,language_rowid INTEGER NOT NULL,pos TEXT NOT NULL);
CREATE TABLE forms(rowid INTEGER PRIMARY KEY,entry_rowid INTEGER NOT NULL,form TEXT NOT NULL,normalized_form TEXT NOT NULL,rank INTEGER DEFAULT 1);
CREATE INDEX idx_forms_normalized ON forms(normalized_form);
CREATE TABLE synsets(rowid INTEGER PRIMARY KEY,ili TEXT,pos TEXT NOT NULL);
CREATE TABLE senses(rowid INTEGER PRIMARY KEY,entry_rowid INTEGER NOT NULL,synset_rowid INTEGER NOT NULL,sense_index INTEGER DEFAULT 1);
CREATE TABLE relation_types(rowid INTEGER PRIMARY KEY,type TEXT NOT NULL);
CREATE TABLE sense_relations(rowid INTEGER PRIMARY KEY,source_rowid INTEGER NOT NULL,target_rowid INTEGER NOT NULL,type_rowid INTEGER NOT NULL);
CREATE TABLE synset_relations(rowid INTEGER PRIMARY KEY,source_rowid INTEGER NOT NULL,target_rowid INTEGER NOT NULL,type_rowid INTEGER NOT NULL);
INSERT INTO languages VALUES(1,'en','English'),(2,'es','Spanish');
""")
    relation_names = [*sorted(proposals.SCORING_RELATIONS), "other", "exemplifies", "is_exemplified_by"]
    connection.executemany("INSERT INTO relation_types VALUES(?,?)", enumerate(relation_names, 1))
    relations = dict(connection.execute("SELECT type,rowid FROM relation_types"))
    concepts = {
        1: [("en", "flooding")],
        2: [("en", "bank"), ("en", "shore"), ("en", "river bank")],
        3: [("en", "bank"), ("en", "financial institution")],
        4: [("en", "clue")],
        5: [("en", "poodle"), ("en", "caniche"), ("es", "caniche")],
        6: [("en", "dog"), ("en", "domestic dog"), ("es", "perro")],
        7: [("en", "domestic animal")],
        8: [("en", "animal")],
        9: [("en", "being")],
        10: [("en", "biology")],
        11: [("en", "noise one"), ("en", "river bank")],
        12: [("en", "noise two"), ("en", "river bank")],
        13: [("en", "noise three"), ("en", "river bank")],
        14: [("en", "noise four"), ("en", "river bank")],
        15: [("en", "noise five"), ("en", "river bank")],
        16: [("en", "noise six"), ("en", "river bank")],
        17: [("en", "ignored")],
    }
    languages = {"en": 1, "es": 2}
    entry = form = sense = 0
    for concept, values in concepts.items():
        connection.execute("INSERT INTO synsets VALUES(?,NULL,'NOUN')", (concept,))
        for language, value in values:
            entry += 1
            form += 1
            sense += 1
            connection.execute("INSERT INTO entries VALUES(?,?,'NOUN')", (entry, languages[language]))
            connection.execute("INSERT INTO forms VALUES(?,?,?,?,0)", (form, entry, value, value))
            connection.execute("INSERT INTO senses VALUES(?,?,?,1)", (sense, entry, concept))
    edges = [
        (1, 2, "causes"),
        (4, 5, "also"),
        (5, 6, "hypernym"),
        (6, 7, "hypernym"),
        (7, 8, "hypernym"),
        (8, 9, "hypernym"),
        (5, 10, "domain_topic"),
        (11, 12, "also"),
        (12, 13, "also"),
        (13, 14, "also"),
        (14, 15, "also"),
        (15, 16, "also"),
        (16, 11, "also"),
        (5, 17, "other"),
    ]
    connection.executemany(
        "INSERT INTO synset_relations(source_rowid,target_rowid,type_rowid) VALUES(?,?,?)",
        ((left, right, relations[relation]) for left, right, relation in edges),
    )
    connection.commit()
    connection.close()
    return database


def service(root):
    database = source(root)
    digest = hashlib.sha256(database.read_bytes()).hexdigest()
    return proposals.Proposals(database, digest)


def test_canonical_source_is_verified_and_used_directly():
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        database = source(root)
        try:
            proposals.Proposals(database, "0" * 64)
            raise AssertionError("bad source hash succeeded")
        except ValueError as error:
            assert "SHA-256" in str(error)
        instance = proposals.Proposals(database, hashlib.sha256(database.read_bytes()).hexdigest())
        assert instance.database == database.resolve()
        assert instance.metadata["concepts"] == 17
        assert instance.metadata["ready"] is True
        assert instance.concept_form_counts[("en", instance.concept_ids[2])] == 3
        assert instance.concept_form_counts[("en", instance.concept_ids[3])] == 2
        compressed = root / "cygnet.db.gz"
        with database.open("rb") as input_file, gzip.open(compressed, "wb") as output_file:
            output_file.write(input_file.read())
        compressed_instance = proposals.Proposals(
            compressed, hashlib.sha256(compressed.read_bytes()).hexdigest()
        )
        assert compressed_instance.database != database.resolve()
        assert compressed_instance.metadata["concepts"] == 17


def test_raw_literals_never_depend_on_cygnet_selection():
    with tempfile.TemporaryDirectory() as temporary:
        terms = service(pathlib.Path(temporary)).propose("velvet-2048 sqlite3_open_v2 !!!", 1, 1e300, 4096)["terms"]
        assert "velvet-2048" in terms
        assert "sqlite3_open_v2" in terms
        assert {"velvet", "2048", "sqlite3", "open", "v2"} <= set(terms)


def test_attention_activates_every_sense_and_rejected_longest_forms_expose_components():
    with tempfile.TemporaryDirectory() as temporary:
        instance = service(pathlib.Path(temporary))
        bank = instance.inspect("bank", 0, -1e300, 4096)
        assert bank["seed_senses"] == 2
        terms = set(bank["terms"])
        assert {"bank", "shore", "river bank", "financial institution"} <= terms
        bank_attention = min(item["attention"] for item in bank["accepted_forms"])
        river = instance.inspect("river bank", 0, -1e300, 4096)
        river_attention = next(item["attention"] for item in river["accepted_forms"] if item["form"] == "river bank")
        assert bank_attention > river_attention
        fallback = set(instance.propose("river bank", 0, (bank_attention + river_attention) / 2, 4096)["terms"])
        assert {"shore", "financial institution"} <= fallback
        rejected = set(instance.propose("bank", 4, 1e300, 4096)["terms"])
        assert rejected == {"bank"}


def test_steps_are_exhaustive_directed_multilingual_and_cycle_safe():
    with tempfile.TemporaryDirectory() as temporary:
        instance = service(pathlib.Path(temporary))
        expected = [
            {"poodle", "caniche"},
            {"dog", "domestic dog"},
            {"domestic animal"},
            {"animal"},
            {"being"},
        ]
        prior = set()
        for steps in range(5):
            current = set(instance.propose("poodle", steps, -1e300, 4096)["terms"])
            assert expected[steps] <= current
            for later in expected[steps + 1:]:
                assert current.isdisjoint(later)
            assert "biology" not in current
            assert "ignored" not in current
            assert prior <= current
            prior = current
        assert "poodle" not in set(instance.propose("dog", 4, -1e300, 4096)["terms"])
        spanish = set(instance.propose("perro", 0, -1e300, 4096)["terms"])
        assert "perro" in spanish and "dog" not in spanish


def test_term_limit_preserves_order_and_reports_truncation():
    with tempfile.TemporaryDirectory() as temporary:
        instance = service(pathlib.Path(temporary))
        full = instance.propose("velvet-2048 sqlite3_open_v2", 1, 1e300, 4096)
        limited = instance.propose("velvet-2048 sqlite3_open_v2", 1, 1e300, 2)
        assert limited == {"terms": full["terms"][:2], "truncated": True}
        exact = instance.propose("bank", 0, -1e300, 4096)
        assert exact["truncated"] is False
        for maximum in (0, 4097, True):
            try:
                instance.propose("bank", 0, 0, maximum)
                raise AssertionError("invalid maximum succeeded")
            except ValueError as error:
                assert "maximum_terms" in str(error)
