#!/usr/bin/env python3
import json
import sqlite3
from support import Package

package = Package()
try:
    value = package.lua(r'''
local store=require('./src/store.lua'){store='store',store_bytes=100000}
local parent=store:begin{actor='actor',snapshot=store:snapshot(),request='parent request'}
local child=store:begin{actor='actor',parent=parent,snapshot=store:snapshot(),request='child request'}
store:append(child,{type='response',source='tool',value={role='tool',tool_call_id='x',content='child evidence'}})
store:append(child,{type='response',source='zinc',value='child answer'})
store:merge(child,parent)
local discarded=store:begin{actor='actor',parent=parent,snapshot=store:snapshot(),request='discard me'}
store:append(discarded,{type='response',source='zinc',value='gone'})
store:index{{idx=discarded,actor='actor',vector=(function()local v={1};for i=2,1024 do v[i]=0 end;return v end)()}}
store:discard(discarded,parent)
store:append(parent,{type='response',source='zinc',value='parent answer'})
local other=store:begin{actor='other',snapshot=store:snapshot(),request='other request'}
store:append(other,{type='response',source='zinc',value='other answer'})
local snapshot=store:snapshot()
local tail,bytes=store:tail('actor',snapshot,100000)
local empty=store:tail('actor',snapshot,1)
local ids={};for _,slice in ipairs(tail) do ids[#ids+1]=slice.idx end
local missing=store:missing(ids)
local vector={1};for i=2,1024 do vector[i]=0 end
local indexed={};for _,idx in ipairs(missing) do indexed[#indexed+1]={idx=idx,actor='actor',vector=vector} end
store:index(indexed)
local nearest=store:nearest(vector,'actor',tail[1].idx,snapshot,3)
local fetched=store:fetch({tail[#tail].idx,tail[1].idx},'actor',snapshot)
local visible=store:visibleSlice('actor',snapshot,parent)
local hidden=store:visibleSlice('other',snapshot,parent)
local childRun=store:visibleRun('actor',snapshot,child,100000)
local noMissing=store:missing(ids)
store:close()
return {parent=parent,child=child,ids=ids,bytes=bytes,empty=#empty,nearest=#nearest,fetched={fetched[1].idx,fetched[2].idx},visible=visible.value,hidden=hidden,childLast=childRun[#childRun].type,noMissing=#noMissing,snapshot=snapshot}
''', ("src/store.lua",))
    assert value["parent"] == 1 and value["child"] == 2
    assert value["ids"] == sorted(value["ids"]) and value["empty"] == 0 and value["bytes"] > 0
    assert value["nearest"] == 3 and value["fetched"] == [value["ids"][-1], value["ids"][0]]
    assert value["visible"] == "parent request" and value.get("hidden") is None
    assert value["childLast"] == "merged" and value["noMissing"] == 0
    database = package.home / ".agents/zinc/store/zinc.sqlite3"
    connection = sqlite3.connect(database)
    assert [row[1] for row in connection.execute("PRAGMA table_info(slices)")] == ["idx", "run", "actor", "data"]
    assert connection.execute("PRAGMA user_version").fetchone()[0] == 4
    schema = connection.execute("SELECT sql FROM sqlite_master WHERE name='slice_vec'").fetchone()[0]
    assert "float[1024]" in schema and "slice_fts" not in {row[0] for row in connection.execute("SELECT name FROM sqlite_master")}
    assert connection.execute("SELECT count(*) FROM slices WHERE actor='other'").fetchone()[0] == 2
    assert connection.execute("SELECT count(*) FROM slices WHERE json_extract(data,'$.value')='gone'").fetchone()[0] == 0
    connection.close()
finally:
    package.close()
print("ok store")
