#!/usr/bin/env python3
"""Bounded proposal service over canonical Cygnet."""

import argparse
import gzip
import hashlib
import json
import math
import pathlib
import shutil
import sqlite3
import tempfile
import threading
from collections import defaultdict
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

CYGNET_GZIP_SHA256 = "65e93f3620d7cc5444350d9e204259e961096138767d9ea73403ade38964cc48"
CYGNET_DATABASE_SHA256 = "aae2cdb1418c1435558584a91181e1cb94459f2506c16f2be4b00e81428deaff"
CONTENT_POS = ("NOUN", "VERB", "ADJ", "ADV")
SCORING_RELATIONS = frozenset((
    "pertainym", "derivation", "antonym", "participle", "also", "similar", "attribute",
    "domain_topic", "has_domain_topic", "domain_region", "has_domain_region", "hypernym",
    "hyponym", "mero_part", "holo_part", "mero_substance", "holo_substance", "mero_member",
    "holo_member", "meronym", "holonym", "entails", "is_entailed_by", "causes",
    "is_caused_by", "instance_hypernym", "instance_hyponym",
))
DOMAIN_RELATIONS = frozenset(("domain_topic", "has_domain_topic", "domain_region", "has_domain_region"))
PAGERANK_RESTART = 0.15
PAGERANK_TOLERANCE = 1e-13
PAGERANK_MAXIMUM_ITERATIONS = 200


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize(value: str) -> str:
    return " ".join(value.casefold().split())


@dataclass(frozen=True)
class SemanticTerm:
    normalized: str
    language: str
    attention: float
    concepts: frozenset[int]


class Proposals:
    def __init__(self, source: pathlib.Path, expected_sha256: str | None = None):
        self.temporary: tempfile.TemporaryDirectory[str] | None = None
        source = source.resolve()
        compressed = source.suffix == ".gz"
        expected = expected_sha256 or (CYGNET_GZIP_SHA256 if compressed else CYGNET_DATABASE_SHA256)
        actual = sha256(source)
        if actual != expected:
            raise ValueError(f"{source} SHA-256 is {actual}, expected {expected}")
        if compressed:
            self.temporary = tempfile.TemporaryDirectory(prefix="zinc-cygnet-")
            database = pathlib.Path(self.temporary.name) / "cygnet.db"
            with gzip.open(source, "rb") as input_file, database.open("wb") as output_file:
                shutil.copyfileobj(input_file, output_file)
        else:
            database = source
        self.database = database
        connection = self.connect()
        try:
            self.validate(connection)
            source_ids = [
                row[0]
                for row in connection.execute(
                    "SELECT rowid FROM synsets WHERE pos IN (?,?,?,?) ORDER BY rowid", CONTENT_POS
                )
            ]
            self.source_ids = tuple(source_ids)
            self.concept_ids = {source_id: index for index, source_id in enumerate(source_ids)}
            relations: list[dict[str, set[int]]] = [defaultdict(set) for _ in source_ids]
            expansion: list[set[int]] = [set() for _ in source_ids]
            parameters = tuple(sorted(SCORING_RELATIONS))
            placeholders = ",".join("?" for _ in parameters)
            rows = connection.execute(f"""
SELECT r.source_rowid,t.type,r.target_rowid
FROM synset_relations r JOIN relation_types t ON t.rowid=r.type_rowid
WHERE t.type IN ({placeholders})
UNION ALL
SELECT ss.synset_rowid,t.type,ts.synset_rowid
FROM sense_relations r
JOIN senses ss ON ss.rowid=r.source_rowid
JOIN senses ts ON ts.rowid=r.target_rowid
JOIN relation_types t ON t.rowid=r.type_rowid
WHERE t.type IN ({placeholders})
""", (*parameters, *parameters))
            for source_id, relation, target_id in rows:
                left, right = self.concept_ids.get(source_id), self.concept_ids.get(target_id)
                if left is None or right is None or left == right:
                    continue
                relations[left][relation].add(right)
                if relation not in DOMAIN_RELATIONS:
                    expansion[left].add(right)
            balanced = tuple(
                tuple(tuple(sorted(targets)) for _, targets in sorted(families.items()))
                for families in relations
            )
            self.expansion = tuple(tuple(sorted(targets)) for targets in expansion)
            self.structural_mass = self.pagerank(balanced)
            vocabulary = dict(connection.execute("""
SELECT l.code,count(DISTINCT f.normalized_form)
FROM forms f
JOIN entries e ON e.rowid=f.entry_rowid
JOIN languages l ON l.rowid=e.language_rowid
WHERE e.pos IN (?,?,?,?) AND f.normalized_form<>''
GROUP BY l.code
""", CONTENT_POS))
            normalizations: dict[str, float] = defaultdict(float)
            for language, source_id in connection.execute("""
SELECT DISTINCT l.code,s.synset_rowid
FROM entries e
JOIN languages l ON l.rowid=e.language_rowid
JOIN senses s ON s.entry_rowid=e.rowid
JOIN forms f ON f.entry_rowid=e.rowid
WHERE e.pos IN (?,?,?,?) AND f.normalized_form<>''
""", CONTENT_POS):
                concept = self.concept_ids.get(source_id)
                if concept is not None:
                    normalizations[language] += self.structural_mass[concept]
            self.language_statistics = {
                language: (normalizations[language], int(size))
                for language, size in vocabulary.items()
                if normalizations[language] > 0.0 and size > 0
            }
            self.concept_form_counts = {
                (language, self.concept_ids[source_id]): int(count)
                for language, source_id, count in connection.execute("""
SELECT l.code,s.synset_rowid,count(DISTINCT f.normalized_form)
FROM senses s
JOIN entries e ON e.rowid=s.entry_rowid
JOIN languages l ON l.rowid=e.language_rowid
JOIN forms f ON f.entry_rowid=e.rowid
WHERE e.pos IN (?,?,?,?) AND f.normalized_form<>''
GROUP BY l.code,s.synset_rowid
""", CONTENT_POS)
                if source_id in self.concept_ids
            }
            maximum = connection.execute("""
SELECT max(length(f.normalized_form)-length(replace(f.normalized_form,' ',''))+1)
FROM forms f JOIN entries e ON e.rowid=f.entry_rowid
WHERE e.pos IN (?,?,?,?) AND f.normalized_form<>''
""", CONTENT_POS).fetchone()[0]
            self.maximum_form_tokens = int(maximum or 1)
        finally:
            connection.close()
        self.metadata = {
            "source_sha256": actual,
            "concepts": len(self.source_ids),
            "maximum_form_tokens": self.maximum_form_tokens,
            "ready": True,
        }

    def connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(f"file:{self.database}?mode=ro&immutable=1", uri=True)
        connection.execute("PRAGMA automatic_index=OFF")
        connection.execute("CREATE TEMP TABLE request_tokens(position INTEGER PRIMARY KEY,token TEXT NOT NULL)")
        return connection

    @staticmethod
    def validate(connection: sqlite3.Connection) -> None:
        required = {
            "languages": {"rowid", "code"},
            "entries": {"rowid", "language_rowid", "pos"},
            "forms": {"entry_rowid", "form", "normalized_form"},
            "synsets": {"rowid", "pos"},
            "senses": {"rowid", "entry_rowid", "synset_rowid"},
            "relation_types": {"rowid", "type"},
            "sense_relations": {"source_rowid", "target_rowid", "type_rowid"},
            "synset_relations": {"source_rowid", "target_rowid", "type_rowid"},
        }
        for table, columns in required.items():
            actual = {row[1] for row in connection.execute(f"PRAGMA table_info({table})")}
            if not columns <= actual:
                raise ValueError(f"Cygnet table {table} has unexpected columns")
        available = {row[0] for row in connection.execute("SELECT type FROM relation_types")}
        missing = SCORING_RELATIONS - available
        if missing:
            raise ValueError(f"Cygnet is missing relations: {', '.join(sorted(missing))}")

    @staticmethod
    def pagerank(relations: tuple[tuple[tuple[int, ...], ...], ...]) -> tuple[float, ...]:
        count = len(relations)
        if count == 0:
            raise ValueError("Cygnet has no content concepts")
        mass = [1.0 / count] * count
        damping = 1.0 - PAGERANK_RESTART
        for _ in range(PAGERANK_MAXIMUM_ITERATIONS):
            following = [PAGERANK_RESTART / count] * count
            dangling = 0.0
            for source, families in enumerate(relations):
                if not families:
                    dangling += mass[source]
                    continue
                family_share = damping * mass[source] / len(families)
                for targets in families:
                    target_share = family_share / len(targets)
                    for target in targets:
                        following[target] += target_share
            if dangling:
                share = damping * dangling / count
                following = [value + share for value in following]
            difference = sum(abs(left - right) for left, right in zip(mass, following, strict=True))
            mass = following
            if difference <= PAGERANK_TOLERANCE:
                break
        else:
            raise ValueError("Cygnet structural mass did not converge")
        return tuple(mass)

    def load_form_terms(
        self, tokens: list[str], exact_forms: list[str], language: str, connection: sqlite3.Connection
    ) -> dict[str, list[SemanticTerm]]:
        connection.execute("DELETE FROM request_tokens")
        connection.executemany("INSERT INTO request_tokens(position,token) VALUES(?,?)", enumerate(tokens))
        matched = {
            row[0]
            for row in connection.execute("""
WITH RECURSIVE spans(start,stop,normalized_form) AS (
    SELECT position,position,token FROM request_tokens
    UNION ALL
    SELECT spans.start,next.position,spans.normalized_form||' '||next.token
    FROM spans JOIN request_tokens next ON next.position=spans.stop+1
    WHERE spans.stop-spans.start+1<?
)
SELECT DISTINCT spans.normalized_form
FROM spans JOIN forms ON forms.normalized_form=spans.normalized_form
""", (self.maximum_form_tokens,))
        }
        matched.update(normalize(value) for value in exact_forms if "_" in value)
        if not matched:
            return {}
        connection.execute("CREATE TEMP TABLE matched_forms(normalized_form TEXT PRIMARY KEY)")
        try:
            connection.executemany("INSERT OR IGNORE INTO matched_forms VALUES(?)", ((value,) for value in matched))
            grouped: dict[str, set[int]] = defaultdict(set)
            for normalized, source_id in connection.execute("""
SELECT DISTINCT f.normalized_form,s.synset_rowid
FROM matched_forms m
JOIN forms f ON f.normalized_form=m.normalized_form
JOIN entries e ON e.rowid=f.entry_rowid
JOIN languages l ON l.rowid=e.language_rowid
JOIN senses s ON s.entry_rowid=e.rowid
WHERE l.code=? AND e.pos IN (?,?,?,?)
ORDER BY f.normalized_form,s.synset_rowid
""", (language, *CONTENT_POS)):
                concept = self.concept_ids.get(source_id)
                if concept is not None:
                    grouped[normalized].add(concept)
        finally:
            connection.execute("DROP TABLE matched_forms")
        normalization, vocabulary = self.language_statistics[language]
        result = {}
        for normalized, concepts in grouped.items():
            probability = sum(
                self.structural_mass[concept] / self.concept_form_counts[(language, concept)]
                for concept in concepts
            ) / normalization
            attention = -math.log(probability * vocabulary)
            result[normalized] = [SemanticTerm(normalized, language, attention, frozenset(concepts))]
        return result

    def semantic_terms(
        self,
        tokens: list[str],
        exact_forms: list[str],
        language: str,
        attention_cutoff: float,
        connection: sqlite3.Connection,
    ) -> tuple[list[SemanticTerm], list[SemanticTerm]]:
        forms = self.load_form_terms(tokens, exact_forms, language, connection)
        selected, rejected = [], []
        seen: set[tuple[str, str, tuple[int, ...]]] = set()
        rejected_seen: set[tuple[str, str, tuple[int, ...]]] = set()
        offset = 0
        while offset < len(tokens):
            accepted, matched_length = [], 0
            for length in range(min(self.maximum_form_tokens, len(tokens) - offset), 0, -1):
                normalized = normalize(" ".join(tokens[offset:offset + length]))
                values = forms.get(normalized, [])
                accepted = [term for term in values if term.attention >= attention_cutoff]
                for term in values:
                    if term.attention >= attention_cutoff:
                        continue
                    key = (term.normalized, term.language, tuple(sorted(term.concepts)))
                    if key not in rejected_seen:
                        rejected_seen.add(key)
                        rejected.append(term)
                if accepted:
                    matched_length = length
                    break
            if not accepted:
                offset += 1
                continue
            offset += matched_length
            for term in accepted:
                key = (term.normalized, term.language, tuple(sorted(term.concepts)))
                if key not in seen:
                    seen.add(key)
                    selected.append(term)
        for value in exact_forms:
            normalized = normalize(value)
            if "_" not in normalized:
                continue
            for term in forms.get(normalized, []):
                key = (term.normalized, term.language, tuple(sorted(term.concepts)))
                target = selected if term.attention >= attention_cutoff else rejected
                target_seen = seen if term.attention >= attention_cutoff else rejected_seen
                if key not in target_seen:
                    target_seen.add(key)
                    target.append(term)
        return selected, rejected

    def lexicalizations(
        self, concepts: set[int], language: str, connection: sqlite3.Connection
    ) -> list[str]:
        output = set()
        source_ids = [self.source_ids[concept] for concept in sorted(concepts)]
        for offset in range(0, len(source_ids), 500):
            values = source_ids[offset:offset + 500]
            placeholders = ",".join("?" for _ in values)
            output.update(row[0] for row in connection.execute(f"""
SELECT DISTINCT f.normalized_form
FROM senses s
JOIN entries e ON e.rowid=s.entry_rowid
JOIN languages l ON l.rowid=e.language_rowid
JOIN forms f ON f.entry_rowid=e.rowid
WHERE s.synset_rowid IN ({placeholders}) AND l.code=?
  AND e.pos IN (?,?,?,?) AND f.normalized_form<>''
""", (*values, language, *CONTENT_POS)))
        return sorted(output)

    def expand(
        self, selected: list[SemanticTerm], depth: int, maximum_terms: int, connection: sqlite3.Connection
    ) -> list[str]:
        output: list[str] = []
        seen: set[str] = set()
        for term in selected:
            visited = set(term.concepts)
            frontier = set(term.concepts)
            for level in range(depth + 1):
                if level:
                    following = {target for source in frontier for target in self.expansion[source]}
                    following.difference_update(visited)
                    if not following:
                        break
                    visited.update(following)
                    frontier = following
                for value in self.lexicalizations(frontier, term.language, connection):
                    key = value.casefold()
                    if key in seen:
                        continue
                    seen.add(key)
                    output.append(value)
                    if len(output) == maximum_terms:
                        return output
        return output

    def analyze(
        self,
        tokens: list[str],
        exact_forms: list[str],
        semantic_language: str,
        semantic_depth: int,
        attention_cutoff: float,
        maximum_terms: int,
    ) -> tuple[dict[str, Any], tuple[list[SemanticTerm], list[SemanticTerm]]]:
        if not isinstance(tokens, list) or any(
            not isinstance(value, str) or not value or "\0" in value or any(map(str.isspace, value)) for value in tokens
        ):
            raise ValueError("tokens must be an array of FTS tokens")
        if not isinstance(exact_forms, list) or any(not isinstance(value, str) or not value or "\0" in value for value in exact_forms):
            raise ValueError("exact_forms must be an array of nonempty text")
        if not isinstance(semantic_language, str) or semantic_language not in self.language_statistics:
            raise ValueError("semantic_language is unsupported")
        if isinstance(semantic_depth, bool) or not isinstance(semantic_depth, int) or not 0 <= semantic_depth <= 4:
            raise ValueError("semantic_depth must be an integer from zero to four")
        if isinstance(attention_cutoff, bool) or not isinstance(attention_cutoff, (int, float)):
            raise ValueError("semantic_attention_cutoff must be a finite number")
        if isinstance(maximum_terms, bool) or not isinstance(maximum_terms, int) or not 1 <= maximum_terms <= 4096:
            raise ValueError("maximum_terms must be an integer from one to 4096")
        attention_cutoff = float(attention_cutoff)
        if not math.isfinite(attention_cutoff):
            raise ValueError("semantic_attention_cutoff must be a finite number")
        connection = self.connect()
        try:
            selected, rejected = self.semantic_terms(
                tokens, exact_forms, semantic_language, attention_cutoff, connection
            )
            semantic = self.expand(selected, semantic_depth, maximum_terms, connection)
        finally:
            connection.close()
        return {"terms": semantic}, (selected, rejected)

    def propose(
        self,
        tokens: list[str],
        exact_forms: list[str],
        semantic_language: str,
        semantic_depth: int,
        attention_cutoff: float,
        maximum_terms: int,
    ) -> dict[str, Any]:
        return self.analyze(
            tokens, exact_forms, semantic_language, semantic_depth, attention_cutoff, maximum_terms
        )[0]

    def inspect(
        self,
        tokens: list[str],
        exact_forms: list[str],
        semantic_language: str,
        semantic_depth: int,
        attention_cutoff: float,
        maximum_terms: int,
    ) -> dict[str, Any]:
        result, (selected, rejected) = self.analyze(
            tokens, exact_forms, semantic_language, semantic_depth, attention_cutoff, maximum_terms
        )

        def describe(term: SemanticTerm) -> dict[str, Any]:
            return {
                "form": term.normalized,
                "language": term.language,
                "attention": term.attention,
                "senses": len(term.concepts),
            }

        return {
            **result,
            "tokens": tokens,
            "exact_forms": exact_forms,
            "accepted_forms": [describe(term) for term in selected],
            "rejected_forms": [describe(term) for term in rejected],
            "seed_senses": sum(len(term.concepts) for term in selected),
        }


class Handler(BaseHTTPRequestHandler):
    proposals: Proposals
    maximum_request_bytes: int

    def do_GET(self) -> None:
        if self.path == "/health":
            self.respond(200, self.proposals.metadata)
        else:
            self.respond(404, {"error": {"message": "not found"}})

    def do_POST(self) -> None:
        try:
            if self.path not in ("/propose", "/inspect"):
                self.respond(404, {"error": {"message": "not found"}})
                return
            raw_length = self.headers.get("content-length")
            if raw_length is None:
                raise ValueError("content-length is required")
            length = int(raw_length)
            if length < 0 or length > self.maximum_request_bytes:
                raise ValueError("request body size is invalid")
            request = json.loads(self.rfile.read(length))
            expected = {
                "tokens",
                "exact_forms",
                "semantic_language",
                "semantic_depth",
                "semantic_attention_cutoff",
                "maximum_terms",
            }
            if not isinstance(request, dict) or set(request) != expected:
                raise ValueError("request has invalid fields")
            method = self.proposals.inspect if self.path == "/inspect" else self.proposals.propose
            self.respond(200, method(
                request["tokens"],
                request["exact_forms"],
                request["semantic_language"],
                request["semantic_depth"],
                request["semantic_attention_cutoff"],
                request["maximum_terms"],
            ))
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
            self.respond(400, {"error": {"message": str(error)}})
        except Exception as error:
            self.respond(500, {"error": {"message": str(error)}})

    def respond(self, status: int, value: dict[str, Any]) -> None:
        body = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_: Any) -> None:
        pass


class BoundedThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], handler: type[BaseHTTPRequestHandler], concurrency: int):
        super().__init__(address, handler)
        self.slots = threading.BoundedSemaphore(concurrency)

    def process_request(self, request: Any, client_address: Any) -> None:
        self.slots.acquire()
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request: Any, client_address: Any) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cygnet", type=pathlib.Path, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8002)
    parser.add_argument("--concurrency", type=int, default=1)
    parser.add_argument("--maximum-request-bytes", type=int, required=True)
    arguments = parser.parse_args()
    if arguments.concurrency <= 0:
        parser.error("--concurrency must be positive")
    if arguments.maximum_request_bytes <= 0:
        parser.error("--maximum-request-bytes must be positive")
    Handler.proposals = Proposals(arguments.cygnet)
    Handler.maximum_request_bytes = arguments.maximum_request_bytes
    Handler.proposals.metadata["maximum_request_bytes"] = arguments.maximum_request_bytes
    BoundedThreadingHTTPServer((arguments.host, arguments.port), Handler, arguments.concurrency).serve_forever()


if __name__ == "__main__":
    main()
