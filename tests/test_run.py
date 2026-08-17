from support import Package


def test_nested_tool_restores_parent_results_scope_and_persists_completed_records():
    package = Package()
    try:
        events = package.lua_stream(r'''
local json=require('dkjson')
local function encode(value)return assert(json.encode(value))end
local function decode(value)local result,position,error=json.decode(value,1,json.null);assert(not error,error);return result end
package.loaded.host={guide='host guide',value='clean'}
local writes={};local next_id=0
local store={}
function store:begin(actor,request)next_id=next_id+1;local r={id=next_id,actor=actor,start=next_id,role='user',text=request};writes[#writes+1]=r;return r end
function store:append(actor,start,role,text)next_id=next_id+1;local r={id=next_id,actor=actor,start=start,role=role,text=text};writes[#writes+1]=r;return r end
function store:read(actor,start,id)return{actor=actor,start=start,id=id,text='history'}end
function store:around(actor,start,id)return{current=self:read(actor,start,id)}end
local retrieval={}
function retrieval:start(actor,start,anchor)return{actor=actor,start=start,anchor=anchor}end
function retrieval:context()return'{}'end
local function iterator(events)local i=0;return function()i=i+1;return events[i]end end
local rounds={root=0,child=0};local captured={}
local models={encode=encode,decode=function(v)return assert(json.decode(v))end,null=json.null}
function models:chat(messages) captured[#captured+1]=messages
 local request
 for _,message in ipairs(messages)do if message.role=='user'then request=message.content end end
 rounds[request]=rounds[request]+1
 if request=='child' then
  if rounds.child==1 then
   local code=[[return require('results').read(1).start]]
   return iterator{{type='tool'},{type='finish',reason='tool_calls',tool_calls={{id='child',name='run_lua',arguments=encode{code=code}}}}}
  end
  return iterator{{type='response',text='child answer'},{type='finish',reason='stop',tool_calls={}}}
 end
 if rounds.root==1 then
  local code=[[local parent=require('results');parent.ask('child');return parent.read(1).start..':'..require('results').read(1).start]]
  return iterator{{type='tool'},{type='finish',reason='tool_calls',tool_calls={{id='root',name='run_lua',arguments=encode{code=code}}}}}
 end
 return iterator{{type='response',text='final answer'},{type='finish',reason='stop',tool_calls={}}}
end
local agent=require('src.run').new{name='zinc',store=store,retrieval=retrieval,models=models,instructions='instructions'}
agent.ask('root','actor')
coroutine.yield(encode{type='test',writes=writes,captured=captured}..'\n')
''')
        types = [event["type"] for event in events]
        assert types == ["tool_call", "tool_result", "response", "response_complete", "store", "test"]
        result = events[-1]
        writes = result["writes"]
        assert [(r["id"], r["start"], r["role"], r["text"]) for r in writes] == [
            (1, 1, "user", "root"),
            (2, 1, "assistant", "local parent=require('results');parent.ask('child');return parent.read(1).start..':'..require('results').read(1).start"),
            (3, 3, "user", "child"),
            (4, 3, "assistant", "return require('results').read(1).start"),
            (5, 3, "tool", "3"),
            (6, 3, "assistant", "child answer"),
            (7, 1, "tool", "1:1"),
            (8, 1, "assistant", "final answer"),
        ]
        assert events[-2] == {"type": "store", "result": 8, "start": 1}
        final_input = result["captured"][-1]
        assert [message["role"] for message in final_input] == ["system", "system", "user", "assistant", "tool"]
        assert final_input[4]["content"] == "1:1"
    finally:
        package.close()


def test_failed_nested_request_restores_parent_results_scope():
    package = Package()
    try:
        events = package.lua_stream(r'''
local json=require('dkjson');local function encode(v)return assert(json.encode(v))end
local id=0;local store={}
function store:begin(actor,text)id=id+1;return{id=id,start=id,role='user',text=text}end
function store:append(actor,start,role,text)id=id+1;return{id=id,start=start,role=role,text=text}end
function store:read(actor,start,result)return{actor=actor,start=start,id=result,text='history'}end
function store:around()return nil end
local retrieval={};function retrieval:start()return{}end;function retrieval:context()return'{}'end
local function iterator(values)local index=0;return function()index=index+1;return values[index]end end
local rounds={root=0,child=0};local models={encode=encode,decode=function(v)return assert(json.decode(v))end,null=json.null}
function models:chat(messages)
 local request;for _,message in ipairs(messages)do if message.role=='user'then request=message.content end end
 rounds[request]=rounds[request]+1
 if request=='child' then
  if rounds.child==1 then
   return iterator{{type='tool'},{type='finish',reason='tool_calls',tool_calls={{id='child',name='run_lua',arguments=encode{code='return true'}}}}}
  end
  return nil,'provider broke'
 end
 if rounds.root==1 then
  local code=[[local parent=require('results');local ok=pcall(parent.ask,'child');return tostring(ok)..':'..parent.read(1).start..':'..require('results').read(1).start]]
  return iterator{{type='tool'},{type='finish',reason='tool_calls',tool_calls={{id='root',name='run_lua',arguments=encode{code=code}}}}}
 end
 return iterator{{type='response',text='done'},{type='finish',reason='stop',tool_calls={}}}
end
local agent=require('src.run').new{name='zinc',store=store,retrieval=retrieval,models=models,instructions='i'}
agent.ask('root','actor')
''')
        assert events[1] == {"type": "tool_result", "text": "false:1:1", "ok": True, "result": 6}
        assert events[-1]["type"] == "store"
    finally:
        package.close()


def test_last_reasoning_continues_and_each_completed_item_is_persisted():
    package = Package()
    try:
        events = package.lua_stream(r'''
local json=require('dkjson');local function encode(v)return assert(json.encode(v))end
local writes={};local id=0;local store={}
function store:begin(actor,text)id=id+1;local r={id=id,start=id,role='user',text=text};writes[#writes+1]=r;return r end
function store:append(actor,start,role,text)id=id+1;local r={id=id,start=start,role=role,text=text};writes[#writes+1]=r;return r end
local retrieval={};function retrieval:start()return{}end;function retrieval:context()return'{}'end
local round=0;local models={encode=encode,decode=function(v)return assert(json.decode(v))end,null=json.null};function models:chat()
 round=round+1;local values
 if round==1 then values={{type='response',text='not terminal'},{type='reasoning',text='continue'},{type='finish',reason='stop',tool_calls={}}}
 else values={{type='response',text='terminal'},{type='finish',reason='stop',tool_calls={}}}end
 local i=0;return function()i=i+1;return values[i]end
end
local agent=require('src.run').new{name='zinc',store=store,retrieval=retrieval,models=models,instructions='i'}
agent.ask('request','actor');coroutine.yield(encode{type='test',writes=writes,rounds=round}..'\n')
''')
        assert events[-1]["rounds"] == 2
        assert [(record["role"], record["text"]) for record in events[-1]["writes"]] == [
            ("user", "request"),
            ("assistant", "not terminal"),
            ("assistant", "continue"),
            ("assistant", "terminal"),
        ]
        assert [event["type"] for event in events[:-1]] == [
            "response", "reasoning", "response_complete", "reasoning_complete",
            "response", "response_complete", "store",
        ]
    finally:
        package.close()


def test_later_failure_preserves_completed_steps_and_omits_unfinished_response():
    package = Package()
    try:
        events = package.lua_stream(r'''
local json=require('dkjson');local function encode(v)return assert(json.encode(v))end;local function decode(v)return assert(json.decode(v))end
local writes={};local id=0;local store={}
function store:begin(actor,text)id=id+1;local r={id=id,start=id,role='user',text=text};writes[#writes+1]=r;return r end
function store:append(actor,start,role,text)id=id+1;local r={id=id,start=start,role=role,text=text};writes[#writes+1]=r;return r end
local retrieval={};function retrieval:start()return{}end;function retrieval:context()return'{}'end
local round=0;local models={encode=encode,decode=function(v)return assert(json.decode(v))end,null=json.null}
function models:chat()
 round=round+1
 if round==1 then
  local i=0;return function()i=i+1;if i==1 then return{type='tool'}elseif i==2 then return{type='finish',reason='tool_calls',tool_calls={{id='x',name='run_lua',arguments=encode{code="return 'kept'"}}}}end end
 end
 local i=0;return function()i=i+1;if i==1 then return{type='response',text='unfinished'}end;return nil,'provider broke'end
end
local agent=require('src.run').new{name='zinc',store=store,retrieval=retrieval,models=models,instructions='i'}
local ok,failure=pcall(agent.ask,'request','actor')
coroutine.yield(encode{type='test',ok=ok,failure=tostring(failure),writes=writes}..'\n')
''')
        value = events[-1]
        assert value["ok"] is False and "provider broke" in value["failure"]
        assert [(r["role"], r["text"]) for r in value["writes"]] == [
            ("user", "request"),
            ("assistant", "return 'kept'"),
            ("tool", "kept"),
        ]
    finally:
        package.close()


def test_persistence_failure_prevents_completed_tool_exposure():
    package = Package()
    try:
        events = package.lua_stream(r'''
local json=require('dkjson');local function encode(v)return assert(json.encode(v))end
local store={};function store:begin()return{id=1}end;function store:append()error('disk failed')end
local retrieval={};function retrieval:start()return{}end;function retrieval:context()return'{}'end
local models={encode=encode,decode=function(v)return assert(json.decode(v))end,null=json.null}
function models:chat()local i=0;return function()i=i+1;if i==1 then return{type='tool'}elseif i==2 then return{type='finish',reason='tool_calls',tool_calls={{id='x',name='run_lua',arguments=encode{code='return 1'}}}}end end end
local agent=require('src.run').new{name='zinc',store=store,retrieval=retrieval,models=models,instructions='i'}
local ok,failure=pcall(agent.ask,'request','actor');coroutine.yield(encode{type='test',ok=ok,failure=tostring(failure)}..'\n')
''')
        assert len(events) == 1
        assert events[0]["type"] == "test" and events[0]["ok"] is False
        assert "disk failed" in events[0]["failure"]
    finally:
        package.close()
