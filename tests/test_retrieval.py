from support import Package


OPTIONS = """{
 semantic_language='en',semantic_depth=1,semantic_attention_cutoff=0,
 max_chronological_window_bytes=100,max_retrieval_window_bytes=1000,
 max_proposal_terms=512,max_retrieval_candidates=64
}"""


def test_one_pass_uses_store_grounding_original_anchor_and_complete_record_lanes():
    package = Package()
    try:
        value = package.lua(r'''
local json=require('dkjson')
local chronological={{id=5,role='assistant',text='recent'},{id=4,role='tool',text=string.rep('x',200)},{id=3,role='user',text='older'}}
local candidates={{id=5,role='assistant',text='recent'},{id=1,role='user',text='first'},{id=2,role='tool',text='second'}}
local store={searches=0}
function store:before(actor,start,visit)for _,record in ipairs(chronological)do if visit(record)==false then break end end end
function store:ground(anchor,maximum)self.anchor=anchor;self.ground_maximum=maximum;return{terms={'anchor'},tokens={'immutable','anchor'},exact_forms={}}end
function store:search(actor,start,terms,maximum)self.searches=self.searches+1;self.terms=terms;self.maximum=maximum;return candidates end
local models={encode=function(value)return assert(json.encode(value))end,proposals=0,reranks=0}
function models:propose(request)self.proposals=self.proposals+1;self.request=request;return{'M-17'}end
function models:rerank(query,passages)self.reranks=self.reranks+1;self.query=query;self.passages=passages;return{{index=2,score=1},{index=1,score=1}},2 end
local retrieval=require('src.retrieval').new(store,models,''' + OPTIONS + r''')
local state=retrieval:start('actor',6,'immutable anchor')
return{context=json.decode(retrieval:context(state)),searches=store.searches,terms=store.terms,
 proposals=models.proposals,reranks=models.reranks,request=models.request,query=models.query,passages=models.passages}
''')
        assert value["searches"] == value["proposals"] == value["reranks"] == 1
        assert value["terms"] == ["anchor", "M-17"]
        assert value["request"] == {
            "tokens": ["immutable", "anchor"],
            "exact_forms": [],
            "semantic_language": "en",
            "semantic_depth": 1,
            "semantic_attention_cutoff": 0,
            "maximum_terms": 511,
        }
        assert value["query"] == "immutable anchor"
        assert value["context"]["chronological"] == [{"id": 5, "role": "assistant", "text": "recent"}]
        assert [record["id"] for record in value["context"]["semantic"]] == [1, 2]
    finally:
        package.close()


def test_local_term_saturation_skips_proposal():
    package = Package()
    try:
        value = package.lua(r'''
local json=require('dkjson');local store={}
function store:before()end
function store:ground()return{terms={'one','two'},tokens={},exact_forms={}}end
function store:search(actor,start,terms)self.terms=terms;return{}end
local models={encode=function(value)return assert(json.encode(value))end}
function models:propose()error('proposal must not run')end
function models:rerank()error('reranker must not run')end
local retrieval=require('src.retrieval').new(store,models,{
 semantic_language='en',semantic_depth=1,semantic_attention_cutoff=0,
 max_chronological_window_bytes=10,max_retrieval_window_bytes=10,
 max_proposal_terms=2,max_retrieval_candidates=10})
local state=retrieval:start('actor',1,'anchor');return{terms=store.terms,context=json.decode(retrieval:context(state))}
''')
        assert value["terms"] == ["one", "two"]
        assert value["context"]["semantic"] == []
    finally:
        package.close()


def test_proposal_and_reranker_failures_are_explicit():
    package = Package()
    try:
        value = package.lua(r'''
local store={};function store:before()end
function store:ground()return{terms={},tokens={'anchor'},exact_forms={}}end
function store:search()return{{id=1,role='user',text='x'}}end
local models={encode=function(value)return require('dkjson').encode(value)end}
function models:propose()return nil,'proposal offline'end
local retrieval=require('src.retrieval').new(store,models,''' + OPTIONS + r''')
local first,one=pcall(retrieval.start,retrieval,'actor',2,'anchor')
function models:propose()return{'x'}end;function models:rerank()return nil,'reranker offline'end
local second,two=pcall(retrieval.start,retrieval,'actor',2,'anchor')
return{first=first,one=tostring(one),second=second,two=tostring(two)}
''')
        assert value["first"] is False and "proposal offline" in value["one"]
        assert value["second"] is False and "reranker offline" in value["two"]
    finally:
        package.close()


def test_semantic_depth_is_bounded():
    package = Package()
    try:
        value = package.lua(r'''
local retrieval=require('src.retrieval');local store={};local models={encode=function()return'{}'end}
local function attempt(depth)return pcall(retrieval.new,store,models,{semantic_language='en',semantic_depth=depth,semantic_attention_cutoff=0,max_chronological_window_bytes=1,max_retrieval_window_bytes=1,max_proposal_terms=1,max_retrieval_candidates=1})end
return{negative=attempt(-1),zero=attempt(0),four=attempt(4),five=attempt(5)}
''')
        assert value == {"negative": False, "zero": True, "four": True, "five": False}
    finally:
        package.close()
