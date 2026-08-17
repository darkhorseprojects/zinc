#!/usr/bin/env python3
"""Verify live Zinc proposal, reranker, and chat deployments."""

import argparse
import json
import pathlib
import tomllib
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
with (ROOT / "dependencies.lock").open("rb") as source:
    DEPENDENCIES = {value["name"]: value for value in tomllib.load(source)["dependency"]}
RERANKER = urllib.parse.urlparse(DEPENDENCIES["llama-nemotron-rerank-1b-v2"]["source"]).path.lstrip("/")
RERANKER_REVISION = DEPENDENCIES["llama-nemotron-rerank-1b-v2"]["revision"]
CHAT_MODEL = urllib.parse.urlparse(DEPENDENCIES["LFM2.5-2.6B-GGUF"]["source"]).path.lstrip("/")
CHAT_REVISION = DEPENDENCIES["LFM2.5-2.6B-GGUF"]["revision"]


def get(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.load(response)


def post(url, value, timeout=900):
    request = urllib.request.Request(url, data=json.dumps(value).encode(), headers={"content-type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--proposals", default="http://127.0.0.1:8002")
    parser.add_argument("--reranker", default="http://127.0.0.1:8001")
    parser.add_argument("--chat", default="http://127.0.0.1:8000")
    parser.add_argument("--minimum-chat-context", type=int, default=130000)
    parser.add_argument("--maximum-request-bytes", type=int, default=1048576)
    args = parser.parse_args()

    proposal_health = get(args.proposals + "/health")
    if (
        not proposal_health.get("ready")
        or len(proposal_health.get("source_sha256", "")) != 64
        or proposal_health.get("maximum_request_bytes") != args.maximum_request_bytes
    ):
        raise SystemExit("canonical Cygnet service is invalid")
    proposed = post(args.proposals + "/propose", {
        "tokens": ["meridian", "credential", "rollback"],
        "exact_forms": [],
        "semantic_language": "en",
        "semantic_depth": 1,
        "semantic_attention_cutoff": 0,
        "maximum_terms": 512,
    })
    if not proposed.get("terms"):
        raise SystemExit("proposal service returned no terms")

    models = get(args.reranker + "/v1/models")
    if RERANKER not in {item.get("id") for item in models.get("data", [])}:
        raise SystemExit("pinned reranker is not served")
    ranked = post(args.reranker + "/rerank", {
        "model": RERANKER,
        "query": "What credential does Meridian require?",
        "documents": ["Routine weather report.", "Meridian requires credential velvet-2048."],
        "top_n": 2,
    })
    if [item.get("index") for item in ranked.get("results", [])] != [1, 0]:
        raise SystemExit("reranker response or ordering is invalid")

    chat_models = get(args.chat + "/v1/models")
    chat = [item for item in chat_models.get("data", []) if item.get("id") == CHAT_MODEL]
    contexts = [item.get("meta", {}).get("n_ctx") or item.get("context_length") for item in chat]
    contexts = [value for value in contexts if isinstance(value, int)]
    if not contexts or max(contexts) < args.minimum_chat_context:
        raise SystemExit(f"chat server does not report at least {args.minimum_chat_context} effective context tokens")
    print(json.dumps({
        "proposal_terms": len(proposed["terms"]),
        "reranker": RERANKER,
        "reranker_revision": RERANKER_REVISION,
        "chat": CHAT_MODEL,
        "chat_revision": CHAT_REVISION,
        "chat_context": max(contexts),
    }))


if __name__ == "__main__":
    main()
