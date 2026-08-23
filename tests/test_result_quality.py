import json
import os

import pytest

from support import Package


@pytest.mark.model
def test_pinned_reranker_finds_the_grounded_record_without_chunks():
    if os.environ.get("ZINC_MODELS") != "1":
        pytest.fail("set ZINC_MODELS=1 and start proposal and pinned reranking services")
    ordinary = [f"Routine record {index} concerns subject {index % 12}." for index in range(48)]
    target = "Meridian Ledger control M-17 requires credential velvet-2048 and Northstar approval."
    package = Package()
    try:
        corpus = package.root / "corpus.json"
        corpus.write_text(json.dumps({"ordinary": ordinary, "target": target}))
        package.environment["CORPUS"] = str(corpus)
        value = package.lua(r'''
local json=require('dkjson');local file=assert(io.open(os.getenv('CORPUS'),'rb'));local corpus=json.decode(file:read('*a'));file:close()
local store=require('src.store').open{path='store',max_stored_record_bytes=524288}
local models=require('src.models').new({chat={endpoint='unused',model='unused'},
 propose={endpoint='http://127.0.0.1:8002/propose'},
 rerank={endpoint='http://127.0.0.1:8001/rerank',model='nvidia/llama-nemotron-rerank-1b-v2'},max_model_request_bytes=1048576},require('src.sse'))
for _,text in ipairs(corpus.ordinary)do store:begin('quality',text)end
local target=store:begin('quality',corpus.target).id;local current=store:begin('quality','What credential and approval does Meridian Ledger require?')
local retrieval=require('src.retrieval').new(store,models,{semantic_language='en',semantic_depth=1,semantic_attention_cutoff=0,max_chronological_window_bytes=64,max_retrieval_window_bytes=32768,max_proposal_terms=512,max_retrieval_candidates=64})
local context=json.decode(retrieval:context(retrieval:start('quality',current.id,current.text)));local ids={};for _,record in ipairs(context.semantic)do ids[#ids+1]=record.id end
store:close();return{ids=ids,target=target}
''', ("src.store", "src.models"), timeout=900)
        assert value["target"] in value["ids"][:8]
    finally:
        package.close()
