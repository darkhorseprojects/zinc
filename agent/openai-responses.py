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
    api_key = os.environ.get("OPENAI_API_KEY") or first_arg(config, "api-key") or "local"
    return OpenAI(api_key=api_key, base_url=base_url)


def model_for(config: kdl.Document) -> str:
    model = os.environ.get("ZINC_MODEL") or first_arg(config, "model")
    if not model:
        raise SystemExit("model is required")
    return model


def response_data(response: Any) -> dict[str, Any]:
    if hasattr(response, "model_dump"):
        return response.model_dump()
    if isinstance(response, dict):
        return response
    raise RuntimeError("OpenAI response object cannot be normalized")


def extract_text(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(text for item in value if (text := extract_text(item)))
    if isinstance(value, dict):
        for key in ("text", "content", "output_text"):
            text = value.get(key)
            if isinstance(text, str):
                return text
    return ""


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


def normalize(data: dict[str, Any]) -> dict[str, str]:
    output = data.get("output")
    items = output if isinstance(output, list) else []
    texts: list[str] = []
    reasoning: list[str] = []

    for item in items:
        if not isinstance(item, dict):
            continue
        if item.get("type") == "reasoning":
            text = extract_text(item.get("summary")) or extract_text(item.get("content"))
            if text:
                reasoning.append(text)
        elif item.get("type") == "message":
            text = extract_text(item.get("content"))
            if text:
                texts.append(text)

    output_text = data.get("output_text")
    if isinstance(output_text, str) and output_text.strip():
        texts.append(output_text.strip())

    structured = parse_structured_text("\n".join(texts))
    result: dict[str, str] = {}
    if reasoning or structured.get("reasoning"):
        result["reasoning"] = "\n".join(part for part in ["\n".join(reasoning), structured.get("reasoning", "")] if part)
    if structured.get("circuitry"):
        result["circuitry"] = structured["circuitry"]
    if structured.get("response"):
        result["response"] = structured["response"]
    return result


def write_output(values: dict[str, str]) -> None:
    nodes = [kdl.Node(name, args=[value]) for name, value in values.items() if value]
    if not nodes:
        raise SystemExit("OpenAI Responses adapter produced no output")
    print(kdl.Document(nodes), end="")


def main() -> int:
    input_doc = kdl.parse(sys.stdin.read())
    config = config_doc()

    context = required_arg(input_doc, "context")
    cwd = required_arg(input_doc, "cwd")
    instructions = required_arg(input_doc, "instructions")
    store = first_arg(input_doc, "store")
    loop_dir = first_arg(input_doc, "loop-dir")

    system_instructions = "\n\n".join(part for part in [
        instructions,
        f"cwd: {cwd}",
        f"store: {store}" if store else "",
        f"loop-dir: {loop_dir}" if loop_dir else "",
    ] if part)

    response = client_for(config).responses.create(
        model=model_for(config),
        instructions=system_instructions,
        input=context,
    )
    write_output(normalize(response_data(response)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
