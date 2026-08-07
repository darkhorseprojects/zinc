#!/usr/bin/env python3
import json
from support import Package

package = Package()
try:
    value = package.lua(r'''
local store=require('./src/store.lua'){store='store',store_bytes=1048576}
local function complete(request,tool,answer)
 local run=store:begin{actor='a',snapshot=store:snapshot(),request=request}
 if tool then store:append(run,{type='response',source='tool',value={role='tool',tool_call_id='evidence',content=tool}}) end
 store:append(run,{type='response',source='zinc',value=answer})
 return run
end
local paragraph=' This paragraph contains operational background, ordinary scheduling details, and enough complete prose to represent a realistic durable event rather than a keyword stub.'
for i=1,40 do complete('Earlier routine record '..i..paragraph,nil,'Earlier routine answer '..i..paragraph) end
local bridge=complete('The Orchid initiative stores deployment credentials in the Archive Vault.'..paragraph,'Inspection confirmed that Archive Vault is the authoritative credential registry.'..paragraph,'Orchid points to Archive Vault.'..paragraph)
local target=complete('Archive Vault credential policy for production releases.'..paragraph,'The current release key is amber-4821 and requires lighthouse approval.'..paragraph,'Vault policy recorded.'..paragraph)
for i=1,40 do complete('Recent unrelated logistics record '..i..paragraph,nil,'Recent logistics answer '..i..paragraph) end
local snapshot=store:snapshot()
complete('Future Orchid note says a false key.'..paragraph,nil,'wrong-9999')
local calls={embed=0,rerank=0}
local provider={}
local function vector(text)
 text=text:lower();local v={}
 for i=1,1024 do v[i]=0 end
 if text:find('orchid',1,true) then v[1]=1 end
 if text:find('archive vault',1,true) or text:find('amber%-4821') then v[2]=1 end
 if v[1]==0 and v[2]==0 then v[3]=1 end
 return v
end
function provider:embed(values)
 calls.embed=calls.embed+1;local result={};for i,text in ipairs(values) do result[i]=vector(text) end;return result
end
function provider:rerank(query,documents)
 calls.rerank=calls.rerank+1;local ranked={}
 local bridgeQuery=query:find('Bridge history',1,true)~=nil
 for i,document in ipairs(documents) do
  local score=0
  if bridgeQuery and document:find('amber%-4821') then score=100
  elseif document:find('Orchid',1,true) then score=90
  elseif document:find('Archive Vault',1,true) then score=bridgeQuery and 80 or 10
  else score=i/100000 end
  ranked[#ranked+1]={index=i,score=score}
 end
 table.sort(ranked,function(a,b)return a.score==b.score and a.index<b.index or a.score>b.score end)
 return ranked
end
local function select(hops)
 local memory=require('./src/memory.lua')({store_bytes=1048576,context_bytes=3000,hops=hops},store,provider)
 return memory:select{actor='a',snapshot=snapshot,request='Which release key and approval does the Orchid initiative require?'}
end
local one=select(1)
local two=select(2)
local decoded=require('dkjson').decode(two.text)
local access=require('./src/memory.lua')({store_bytes=1048576,context_bytes=3000,hops=2},store,provider):access('a',snapshot)
local targetRun=access.run(target)
local hidden=access.slice(store:snapshot())
local bytes=#two.text
store:close()
return {one=one.slices,two=two.slices,records=decoded,bridge=bridge,target=target,targetRun=#targetRun,hidden=hidden,bytes=bytes,calls=calls}
''', ("src/store.lua", "src/memory.lua"))
    assert value["target"] not in value["one"], value
    assert value["bridge"] in value["two"] and value["target"] in value["two"], value
    target_records = [item for item in value["records"] if item["run"] == value["target"]]
    assert target_records and any(item["hop"] == 2 for item in target_records), value
    assert any(item["relation"] in {"previous", "next"} for item in target_records), value
    assert all({"rank", "hop", "slice", "run", "actor", "source", "relation", "value"} <= item.keys() for item in value["records"])
    assert value["targetRun"] == 3 and value.get("hidden") is None
    assert value["bytes"] <= 3000 and value["calls"]["embed"] > 0 and value["calls"]["rerank"] >= 3
finally:
    package.close()
print("ok memory")
