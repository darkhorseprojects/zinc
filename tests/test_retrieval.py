from support import Package


def test_one_pass_uses_original_anchor_and_separate_complete_record_lanes():
    package = Package()
    try:
        value = package.lua(r'''
local json=require('dkjson')
local chronological={{id=5,role='assistant',text='recent'},{id=4,role='tool',text=string.rep('x',200)},{id=3,role='user',text='older'}}
local candidates={{id=5,role='assistant',text='recent'},{id=1,role='user',text='first'},{id=2,role='tool',text='second'}}
local store={searches=0}
function store:before(actor,start,visit)for _,record in ipairs(chronological)do if visit(record)==false then break end end end
function store:search(actor,start,terms,maximum)self.searches=self.searches+1;self.actor=actor;self.start=start;self.terms=terms;self.maximum=maximum;return candidates end
local models={encode=function(value)return assert(json.encode(value))end,proposals=0,reranks=0}
function models:propose(text,steps,attention,maximum)self.proposals=self.proposals+1;self.proposal_text=text;self.steps=steps;self.attention=attention;self.maximum=maximum;return{'anchor','M-17'},false end
function models:rerank(query,passages)
 self.reranks=self.reranks+1;self.query=query;self.passages=passages
 return{{index=2,score=1},{index=1,score=1}},2
end
local retrieval=require('src.retrieval').new(store,models,{semantic_steps=3,cygnet_attention_minimum=0,max_chronological_window_bytes=100,max_retrieval_window_bytes=1000,max_proposal_terms=512,max_retrieval_candidates=64,max_rerank_request_bytes=1048576})
local state=retrieval:start('actor',6,'immutable anchor')
return{context=json.decode(retrieval:context(state)),searches=store.searches,terms=store.terms,
 proposals=models.proposals,reranks=models.reranks,proposal_text=models.proposal_text,steps=models.steps,attention=models.attention,
 proposal_maximum=models.maximum,candidate_maximum=store.maximum,query=models.query,passages=models.passages,has_update=retrieval.update~=nil}
''')
        assert [record["id"] for record in value["context"]["chronological"]] == [5]
        assert [record["id"] for record in value["context"]["semantic"]] == [1, 2]
        assert value["searches"] == 1
        assert value["proposals"] == 1 and value["reranks"] == 1
        assert value["proposal_text"] == "immutable anchor"
        assert value["query"] == "immutable anchor"
        assert value["steps"] == 3 and value["attention"] == 0
        assert value["proposal_maximum"] == 512 and value["candidate_maximum"] == 64
        assert value["passages"] == ["user:\nfirst", "tool:\nsecond"]
        assert value["has_update"] is False
    finally:
        package.close()


def test_semantic_packing_stops_at_first_nonfit_without_skipping():
    package = Package()
    try:
        value = package.lua(r'''
local json=require('dkjson')
local records={{id=1,role='user',text='first'},{id=2,role='tool',text=string.rep('x',200)},{id=3,role='tool',text='would fit'}}
local store={};function store:before()end;function store:search()return records end
local models={encode=function(value)return assert(json.encode(value))end}
function models:propose()return{'x'}end
function models:rerank()return{{index=1,score=3},{index=2,score=2},{index=3,score=1}},3 end
local retrieval=require('src.retrieval').new(store,models,{semantic_steps=1,cygnet_attention_minimum=0,max_chronological_window_bytes=10,max_retrieval_window_bytes=100,max_proposal_terms=10,max_retrieval_candidates=10,max_rerank_request_bytes=1000})
return json.decode(retrieval:context(retrieval:start('actor',10,'anchor')))
''')
        assert [record["id"] for record in value["semantic"]] == [1]
    finally:
        package.close()


def test_empty_grounding_skips_reranker_and_preserves_empty_semantic_lane():
    package = Package()
    try:
        value = package.lua(r'''
local json=require('dkjson')
local store={};function store:before()end;function store:search()return{}end
local models={encode=function(value)return assert(json.encode(value))end}
function models:propose(text,steps)return{text,tostring(steps)}end
function models:rerank()error('reranker must not run')end
local retrieval=require('src.retrieval').new(store,models,{semantic_steps=0,cygnet_attention_minimum=0,max_chronological_window_bytes=10,max_retrieval_window_bytes=10,max_proposal_terms=10,max_retrieval_candidates=10,max_rerank_request_bytes=1000})
return json.decode(retrieval:context(retrieval:start('actor',1,'anchor')))
''')
        assert value == {"chronological": [], "semantic": []}
    finally:
        package.close()


def test_proposal_and_reranker_failures_are_explicit():
    package = Package()
    try:
        value = package.lua(r'''
local store={};function store:before()end;function store:search()return{{id=1,role='user',text='x'}}end
local models={encode=function(value)return require('dkjson').encode(value)end}
function models:propose()return nil,'proposal offline'end
local retrieval=require('src.retrieval').new(store,models,{semantic_steps=1,cygnet_attention_minimum=0,max_chronological_window_bytes=10,max_retrieval_window_bytes=100,max_proposal_terms=10,max_retrieval_candidates=10,max_rerank_request_bytes=1000})
local first,one=pcall(retrieval.start,retrieval,'actor',2,'anchor')
function models:propose()return{'x'}end;function models:rerank()return nil,'reranker offline'end
local second,two=pcall(retrieval.start,retrieval,'actor',2,'anchor')
return{first=first,one=tostring(one),second=second,two=tostring(two)}
''')
        assert value["first"] is False and "proposal offline" in value["one"]
        assert value["second"] is False and "reranker offline" in value["two"]
    finally:
        package.close()


def test_semantic_steps_are_bounded():
    package = Package()
    try:
        value = package.lua(r'''
local retrieval=require('src.retrieval');local store={};local models={encode=function()return'{}'end}
local function attempt(steps)return pcall(retrieval.new,store,models,{semantic_steps=steps,cygnet_attention_minimum=0,max_chronological_window_bytes=1,max_retrieval_window_bytes=1,max_proposal_terms=1,max_retrieval_candidates=1,max_rerank_request_bytes=1})end
return{negative=attempt(-1),zero=attempt(0),four=attempt(4),five=attempt(5)}
''')
        assert value == {"negative": False, "zero": True, "four": True, "five": False}
    finally:
        package.close()
