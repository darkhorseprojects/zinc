#!/usr/bin/env python3
import json
import os
from support import Package

if os.environ.get("LLAMACPP_REAL") != "1":
    print("skip memory-models (set LLAMACPP_REAL=1)")
    raise SystemExit(0)

subjects = [
    "municipal water sampling", "orchard irrigation", "railway timetable reconciliation", "museum climate control",
    "bakery inventory", "coastal bird census", "library digitization", "solar array maintenance",
    "textile dye calibration", "school meal planning", "forest trail mapping", "warehouse safety",
]
paragraphs = []
for index in range(48):
    subject = subjects[index % len(subjects)]
    paragraphs.append(
        f"Operational record {index + 1} concerns {subject}. The team met on weekday {(index % 5) + 1} to review routine measurements, "
        f"assign ordinary follow-up work, and document procedure reference R-{3100 + index}. The record emphasizes careful observation, "
        "clear handoffs, and a written summary. Materials, dates, and staff assignments remain within the ordinary subject named at the beginning. "
        "This complete paragraph exists to make the retrieval corpus realistic rather than a list of isolated keywords."
    )
bridge = (
    "Project Lantern continuity work never stores sensitive release instructions under the public project name. Its engineering handbook says that "
    "all authoritative deployment controls are maintained in a separate operational record called the Meridian Ledger. When a Lantern release is "
    "prepared, operators must consult that ledger instead of relying on chat summaries or old tickets. This paragraph establishes the durable link "
    "between the project and its otherwise unrelated control record."
)
target = (
    "Meridian Ledger authoritative control entry M-17. Required Alpha: velvet-2048. Required Beta: Northstar council. Status: active. This entry "
    "supersedes M-16 and requires exact spelling when both values are transcribed. The internal record deliberately does not identify an associated "
    "project, workflow, role, or purpose; its opaque Alpha and Beta labels depend on the separate handbook link to the Meridian Ledger."
)
other = (
    "A separate actor keeps a misleading Meridian Ledger note claiming the phrase is paper-0000 and the reviewer is the Southwind committee. "
    "This paragraph is deliberately plausible but belongs to another actor and must never enter the tested actor's Memory."
)
future = (
    "A future record written after the tested snapshot says Project Lantern uses a changed phrase future-9999. Snapshot isolation must keep this later "
    "event out of retrieval even though its wording directly matches the question."
)

package = Package()
try:
    corpus = package.root / "corpus.json"
    corpus.write_text(json.dumps({"before": paragraphs[:24], "bridge": bridge, "target": target, "after": paragraphs[24:], "other": other, "future": future}))
    package.environment["CORPUS"] = str(corpus)
    value = package.lua(r'''
local json=require('dkjson')
local file=assert(io.open(os.getenv('CORPUS'),'rb'));local corpus=json.decode(file:read('*a'));file:close()
local config={
 store='store',store_bytes=524288,context_bytes=2200,hops=2,
 chat_endpoint='http://127.0.0.1:8000/v1/chat/completions',chat_model='LiquidAI/LFM2.5-2.6B-GGUF',
 embedding_endpoint='http://127.0.0.1:8001/v1/embeddings',embedding_model='Qwen3-Embedding-0.6B',
 rerank_endpoint='http://127.0.0.1:8002/v1/rerank',rerank_model='Qwen3-Reranker-0.6B',
}
local store=require('./src/store.lua')(config)
local function complete(actor,request,response)
 local run=store:begin{actor=actor,snapshot=store:snapshot(),request=request}
 store:append(run,{type='response',source='zinc',value=response or 'Record acknowledged.'})
 return run
end
for _,paragraph in ipairs(corpus.before) do complete('quality',paragraph) end
local bridge=complete('quality',corpus.bridge,'The handbook linkage was recorded.')
local target=complete('quality',corpus.target,'Record acknowledged.')
for _,paragraph in ipairs(corpus.after) do complete('quality',paragraph) end
complete('other',corpus.other)
local snapshot=store:snapshot()
local future=complete('quality',corpus.future)
local provider=require('./src/llamacpp.lua')(config)
local function select(hops)
 config.hops=hops
 local memory=require('./src/memory.lua')(config,store,provider)
 return memory:select{actor='quality',snapshot=snapshot,request='What credential and independent oversight does Project Lantern require before production release?'}
end
local one=select(1)
local two=select(2)
store:close()
return {one=one,two=two,bridge=bridge,target=target,future=future}
''', ("src/store.lua", "src/memory.lua", "src/llamacpp.lua"), timeout=900, deadline="15m")
    one_records = json.loads(value["one"]["text"])
    two_records = json.loads(value["two"]["text"])
    one_runs = {item["run"] for item in one_records}
    two_runs = {item["run"] for item in two_records}
    assert value["bridge"] in two_runs, value
    assert value["target"] in two_runs, value
    assert value["future"] not in two_runs
    assert all(item["actor"] == "quality" for item in two_records)
    assert len(value["two"]["text"].encode()) <= 2200
    one_rank = next((item["rank"] for item in one_records if item["run"] == value["target"]), None)
    two_rank = next(item["rank"] for item in two_records if item["run"] == value["target"])
    assert one_rank is None or two_rank <= one_rank, value
    report = {
        "one_hop_runs": sorted(one_runs),
        "two_hop_runs": sorted(two_runs),
        "bridge_run": value["bridge"],
        "target_run": value["target"],
        "one_hop_target_rank": one_rank,
        "two_hop_target_rank": two_rank,
        "one_hop_found_target": value["target"] in one_runs,
        "two_hop_found_target": value["target"] in two_runs,
        "two_hop_bytes": len(value["two"]["text"].encode()),
        "records": two_records,
    }
    (package.root / "memory-model-report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
finally:
    package.close()
print("ok memory-models")
