import argparse
import base64
import datetime
import json
import os
import selectors
import subprocess
import tempfile
import time
from pathlib import Path

parser = argparse.ArgumentParser(description="Profile local Zinc through the PA CLI without Discord or user Store writes")
parser.add_argument("--agent", type=Path, required=True)
parser.add_argument("--package", type=Path, required=True, help="assembled PA Image source directory")
parser.add_argument("--cygnet", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True, help="metadata-only JSONL profile output")
parser.add_argument("--timeout", type=float, default=180)
parser.add_argument("--follow-up", action="store_true", help="profile a continuation after the initial durable answer")
parser.add_argument("--compare", action="store_true", help="alternate unprofiled and profiled no-history calls")
parser.add_argument("--samples", type=int, default=1, help="number of no-history pairs (default: 1)")
parser.add_argument("--semantic", action="store_true", help="use a shared topic and narrow chronological history to exercise reranking")
args = parser.parse_args()
agent, package, cygnet = (path.resolve(strict=True) for path in (args.agent, args.package, args.cygnet))
if args.samples < 1:
    parser.error("--samples must be positive")


def invoke(label, directory, config, profiled=True):
    request = {
        "version": 1,
        "emits": True,
        "profile": profiled,
        "agents": [{
            "sourceDir": str(package),
            "entryModule": "zinc",
            "limits": {"memoryBytes": 100663296, "instructions": "200000000"},
        }],
        "input": base64.b64encode((
            ("Describe oranges in one short sentence." if label != "continuation" else
             "What did you say about oranges? Answer in one short sentence.") if args.semantic else
            ("Answer in one short sentence." if label != "continuation" else
             "Summarize your previous answer in one short sentence.")
        ).encode()).decode(),
        "config": base64.b64encode(json.dumps(config).encode()).decode(),
    }
    start = time.perf_counter()
    observations = []
    dropped = 0
    first_output = None
    outcome = "missing result"
    expired = False
    with subprocess.Popen(
        [str(agent), "call"], cwd=directory, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ) as child:
        child.stdin.write(json.dumps(request).encode())
        child.stdin.close()
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            pending = b""
            while selector.get_map():
                remaining = args.timeout - (time.perf_counter() - start)
                if remaining <= 0 and not expired:
                    expired = True
                    child.kill()
                for key, _ in selector.select(min(0.5, max(remaining, 0.01))):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    pending += chunk
                    while b"\n" in pending:
                        line, pending = pending.split(b"\n", 1)
                        frame = json.loads(line)
                        received_ms = (time.perf_counter() - start) * 1000
                        if "log" in frame and "atUs" in frame:
                            if len(observations) < 256:
                                observations.append({
                                    "stage": frame["log"], "childUs": frame["atUs"],
                                    "receivedMs": received_ms,
                                })
                            else:
                                dropped += 1
                        elif (frame.get("append") or frame.get("emit")) and first_output is None:
                            first_output = received_ms
                        elif "result" in frame:
                            outcome = "success" if "output" in frame["result"] else frame["result"].get("error", "error")
        child.wait()
    profile = {
        "readyMs": 0,
        "activeMs": 0,
        "totalMs": (time.perf_counter() - start) * 1000,
        "observations": observations,
        "droppedStages": dropped,
        "firstOutputReceivedMs": first_output,
    }
    if expired:
        outcome = "timeout"
    with args.output.open("a") as file:
        file.write(json.dumps({
            "time": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "id": f"local-{label}-{time.time_ns()}", "caseName": label,
            "profiled": profiled, "profile": profile, "outcome": outcome,
        }) + "\n")
    print(f"{label}: {outcome}; first output {first_output} ms; total {profile['totalMs']:.1f} ms")
    return outcome == "success"


with tempfile.TemporaryDirectory(prefix="zinc-profile-") as temporary:
    root = Path(temporary)
    (root / "state").mkdir()
    (root / "data").mkdir()
    (root / "data/cygnet.db").symlink_to(cygnet)
    config = {"version": 1, "actor": "profile:local", "preset": "no-host", "parent": None, "memory": 0}
    complete = False
    for _ in range(args.samples):
        if args.compare:
            invoke("unprofiled", root, config, False)
        complete = invoke("new", root, config)
    if args.follow_up and complete:
        del config["parent"], config["memory"]
        if args.semantic:
            config["retrieval"] = {"chronological": {"records": 1}}
        invoke("continuation", root, config)
    elif args.follow_up:
        print("continuation unavailable: initial call did not complete")
