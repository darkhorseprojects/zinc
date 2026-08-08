#!/usr/bin/env python3
import json
import sqlite3
from support import Package

package = Package()
try:
    value = package.lua(r'''
local json=require('dkjson')
local store=require('./src/store.lua'){store='store',store_bytes=100000}
local code=[=[-- ```
local prior=args.memory.slice(900)
local child=args.run.merge('child work')
local temporary=args.run.discard('discard child work')
return {prior=prior.value,child=child,temporary=temporary,files=args.env.files}
]=]
local provider={}
function provider:arguments(call)local value,_,failure=json.decode(call['function'].arguments,1,json.null);return value,failure end
function provider:toolOutput(value)if value==nil then return '' end;if type(value)=='string'then return value end;return json.encode(value)end
function provider:chat(messages)
 local request=messages[1].content
 if request=='provider error' then return nil,'offline' end
 if request=='child work' then return {role='assistant',content='child answer'} end
 if request=='discard child work' then return {role='assistant',content='discarded child answer'} end
 local tools={};for _,message in ipairs(messages)do if message.role=='tool'then tools[#tools+1]=message end end
 if request=='bad call' and #tools==0 then return {role='assistant',content=json.null,tool_calls={{id='bad',type='function',['function']={name='run_lua',arguments='{}'}}}} end
 if #tools==0 then return {role='assistant',content=json.null,reasoning_content='work',tool_calls={{id='call-1',type='function',['function']={name='run_lua',arguments=json.encode{code=code}}}}} end
 return {role='assistant',content=request=='bad call' and 'corrected' or 'finished'}
end
local selects=0
local memory={}
function memory:select(spec)selects=selects+1;return{slices={900},text='[{"slice":900}]'}end
function memory:access(actor,snapshot)
 return{slice=function(idx)return{idx=idx,run=idx,actor=actor,type='response',source='zinc',value='anchored'}end,run=function()return{}end}
end
local agent=require('./src/run.lua'){
 name='test',actor='default',store=store,memory=memory,provider=provider,
 environment={files='available'},builder={},format=function(m) return m.content or '' end,instructions='instructions',
}
local result={normal=agent.ask('top','actor-42'),bad=agent.ask('bad call','actor-42'),failed=agent.ask('provider error','actor-42'),selects=selects}
store:close();return result
''', ("src/store.lua", "src/run.lua"))
    assert value == {"normal": "finished", "bad": "corrected", "failed": "Provider error: offline", "selects": 3}, value
    connection = sqlite3.connect(package.home / ".agents/zinc/store/zinc.sqlite3")
    slices = [(actor, json.loads(data)) for actor, data in connection.execute("SELECT actor,data FROM slices ORDER BY idx")]
    connection.close()
    assert all(actor == "actor-42" for actor, _ in slices)
    requests = [data for _, data in slices if data["type"] == "request"]
    assert all(data["memory"] == [900] for data in requests)
    assert any(data["type"] == "merged" for _, data in slices)
    tools = [data["value"] for _, data in slices if data.get("source") == "tool"]
    payload = next(json.loads(item["content"]) for item in tools if item["content"].startswith("{"))
    assert payload == {"prior": "anchored", "child": "child answer", "temporary": "discarded child answer", "files": "available"}
    assert not any(data.get("value") == "discard child work" for _, data in slices)
    assert any("requires code" in item["content"] for item in tools)
finally:
    package.close()
print("ok run")
