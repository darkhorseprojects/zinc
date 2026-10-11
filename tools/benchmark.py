import json
import math
import pathlib
import statistics
import subprocess
import sys
import time

count = int(sys.argv[1])
assert count > 0
root = pathlib.Path(__file__).resolve().parents[1]
elapsed = []
for _ in range(count):
    start = time.monotonic()
    result = subprocess.run([sys.executable, str(root / "test/integration.py")], check=True, text=True, capture_output=True)
    elapsed.append(time.monotonic() - start)
    print(result.stdout.strip(), file=sys.stderr)
elapsed.sort()
print(json.dumps({"fixture": "local HTTP + real isolated PA + SQLite", "runs": count, "seconds": elapsed, "p50": statistics.median(elapsed), "p95": elapsed[math.ceil(count * 0.95) - 1]}))
