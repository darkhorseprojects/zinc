#!/usr/bin/env python3
import json
import urllib.request
import urllib.error
import sys

def parse_simple_yaml(filepath):
    # Extremely simple line-based YAML parser for this shape
    data = {"takes": [], "gives": []}
    current_key = None
    does_lines = []
    
    with open(filepath, "r") as f:
        in_does = False
        for line in f:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            
            # Key transitions
            if stripped.startswith("circuitry:"):
                continue
            elif stripped.startswith("name:"):
                data["name"] = stripped.split(":", 1)[1].strip()
                in_does = False
            elif stripped.startswith("about:"):
                data["about"] = stripped.split(":", 1)[1].strip()
                in_does = False
            elif stripped.startswith("takes:"):
                current_key = "takes"
                in_does = False
            elif stripped.startswith("gives:"):
                current_key = "gives"
                in_does = False
            elif stripped.startswith("does:"):
                in_does = True
                # check if multi-line block indicator is present
                remainder = stripped.split(":", 1)[1].strip()
                if remainder != "|":
                    does_lines.append(remainder)
            elif in_does:
                # Keep does indentation or content
                does_lines.append(line.rstrip())
            elif current_key in ("takes", "gives"):
                # Parse list or dict key
                if stripped.startswith("-"):
                    val = stripped[1:].strip()
                    data[current_key].append(val)
                elif ":" in stripped:
                    val = stripped.split(":", 1)[0].strip()
                    data[current_key].append(val)
                    
    data["does"] = "\n".join(does_lines).strip()
    return data

def main():
    shape_path = "examples/compute-math.circuitry.yaml"
    if len(sys.argv) > 1:
        shape_path = sys.argv[1]
        
    print(f"Loading circuitry shape from: {shape_path}")
    try:
        shape = parse_simple_yaml(shape_path)
    except Exception as e:
        print(f"Error parsing shape: {e}")
        sys.exit(1)
        
    print(f"Shape name: {shape.get('name', 'untitled')}")
    print(f"About: {shape.get('about', 'none')}")
    print(f"Takes inputs: {shape['takes']}")
    print(f"Gives outputs: {shape['gives']}")
    print("-" * 50)
    
    # Resolve input values (takes)
    inputs = {}
    default_vals = {"principal": "1000", "rate": "0.05", "years": "5"}
    for t in shape["takes"]:
        default_val = default_vals.get(t, "")
        prompt = f"Enter value for '{t}'"
        if default_val:
            prompt += f" (default: {default_val})"
        prompt += ": "
        
        val = input(prompt).strip()
        if not val and default_val:
            val = default_val
        inputs[t] = val
        
    print(f"\nInputs resolved: {inputs}")
    print("Sending instructions to local llama server at http://127.0.0.1:30000/v1 ...")
    
    # Prepare system instruction and prompt
    system_prompt = (
        "You are a strict, precise calculation engine that executes Circuitry 0.6 shapes.\n"
        "Do not engage in conversation, explanations, or formatting other than the requested JSON structure.\n"
        "Return ONLY a raw, valid JSON object matching the gives structure (no markdown fences, no extra text)."
    )
    
    user_prompt = (
        f"Circuitry Shape Definition:\n"
        f"Name: {shape.get('name')}\n"
        f"Does instructions:\n{shape.get('does')}\n\n"
        f"Inputs (takes):\n" + "\n".join(f"- {k} = {v}" for k, v in inputs.items()) + "\n\n"
        f"Outputs to return (gives):\n" + "\n".join(f"- {g}" for g in shape["gives"]) + "\n\n"
        f"Respond with a JSON object containing keys: {', '.join(shape['gives'])}"
    )
    
    payload = {
        "model": "gemma-4-e4b-it-ultra-uncensored-heretic",
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt}
        ],
        "temperature": 0.0,
        "response_format": {"type": "json_object"}
    }
    
    req = urllib.request.Request(
        "http://127.0.0.1:30000/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"}
    )
    
    try:
        with urllib.request.urlopen(req) as response:
            res_body = response.read().decode("utf-8")
            res_data = json.loads(res_body)
            content = res_data["choices"][0]["message"]["content"].strip()
            
            # Print output (gives)
            print("-" * 50)
            print("Llama Server Response:")
            print(content)
            
            try:
                outputs = json.loads(content)
                print("\nParsed gives:")
                for k, v in outputs.items():
                    print(f"  {k}: {v}")
            except Exception:
                print("\nWarning: Could not parse response as JSON.")
                
    except urllib.error.URLError as e:
        print(f"\nFailed to connect to llama server: {e}")
    except Exception as e:
        print(f"\nError occurred: {e}")

if __name__ == "__main__":
    main()
