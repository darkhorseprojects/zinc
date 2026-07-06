#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path
from typing import Any

import kdl
from openai import OpenAI

HERE = Path(__file__).resolve().parent


def first_arg(doc: kdl.Document, name: str) -> str:
    for node in reversed(doc.nodes):
        if node.name == name and node.args:
            value = node.args[0]
            return value if isinstance(value, str) else str(value)
    return ""


def required_arg(doc: kdl.Document, name: str) -> str:
    value = first_arg(doc, name)
    if not value:
        raise SystemExit(f"{name} is required")
    return value


def config_doc() -> kdl.Document:
    path = HERE / "openai-responses.kdl"
    if not path.exists():
        return kdl.Document([])
    return kdl.parse(path.read_text())


def client_for(config: kdl.Document) -> OpenAI:
    base_url = os.environ.get("OPENAI_BASE_URL") or first_arg(config, "base-url") or None
    # api-key is optional for local endpoints — default to "local" if not set
    api_key = os.environ.get("OPENAI_API_KEY") or first_arg(config, "api-key") or "local"
    return OpenAI(api_key=api_key, base_url=base_url)


def model_for(config: kdl.Document) -> str:
    model = os.environ.get("ZINC_MODEL") or first_arg(config, "model")
    if not model:
        raise SystemExit("model is required — set it in openai-responses.kdl")
    return model


def inference_params(config: kdl.Document) -> dict[str, Any]:
    params: dict[str, Any] = {}
    # Only pass params explicitly set in config — don't override server defaults
    if temp := first_arg(config, "temperature"):
        params["temperature"] = float(temp)
    if max_tok := first_arg(config, "max-tokens"):
        params["max_tokens"] = int(max_tok)
    if top_p := first_arg(config, "top-p"):
        params["top_p"] = float(top_p)
    return params


def parse_structured_text(text: str) -> dict[str, str]:
    stripped = text.strip()
    if not stripped:
        return {}
    if stripped.startswith("```json") and stripped.endswith("```"):
        stripped = stripped.removeprefix("```json").removesuffix("```").strip()
    if stripped.startswith('circuitry "') or stripped.startswith("---"):
        return {"circuitry": stripped}
    try:
        parsed = json.loads(stripped)
    except json.JSONDecodeError:
        return {"response": text}
    if not isinstance(parsed, dict):
        return {"response": text}
    return {
        key: value.strip()
        for key in ("reasoning", "response", "circuitry")
        if isinstance((value := parsed.get(key)), str) and value.strip()
    }


def write_output(values: dict[str, str]) -> None:
    nodes = [kdl.Node(name, args=[value]) for name, value in values.items() if value]
    if not nodes:
        raise SystemExit("OpenAI adapter produced no output")
    print(kdl.Document(nodes), end="")


def main() -> int:
    input_doc = kdl.parse(sys.stdin.read())
    config = config_doc()

    # System prompt comes entirely from Circuitry — no hidden additions
    context = required_arg(input_doc, "context")
    instructions = required_arg(input_doc, "instructions")

    messages = [
        {"role": "system", "content": instructions},
        {"role": "user", "content": context},
    ]

    stream = client_for(config).chat.completions.create(
        model=model_for(config),
        messages=messages,
        stream=True,
        **inference_params(config),
    )

    text = ""
    for chunk in stream:
        if chunk.choices and chunk.choices[0].delta.content:
            text += chunk.choices[0].delta.content

    write_output(parse_structured_text(text))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
