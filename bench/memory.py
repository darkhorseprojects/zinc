#!/usr/bin/env python3
import pathlib
import statistics
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from test.support import Package

SLICES = 100_000
STORE_BYTES = 8 * 1024 * 1024
package = Package()
try:
    package.environment.update(SLICES=str(SLICES), STORE_BYTES=str(STORE_BYTES))
    started = time.perf_counter()
    result = package.lua(r'''
local sqlite=require('lsqlite3')
local json=require('dkjson')
local uv=require('luv')
local path=os.getenv('HOME')..'/.agents/zinc/store'
local store=require('./src/store.lua'){store='store',store_bytes=tonumber(os.getenv('STORE_BYTES'))}
store:close()
local db=assert(sqlite.open(path..'/zinc.sqlite3'))
assert(db:load_extension(assert(package.searchpath('vec0',package.cpath))))
assert(db:exec('PRAGMA synchronous=OFF; BEGIN IMMEDIATE')==sqlite.OK)
local slice=assert(db:prepare('INSERT INTO slices(idx,run,actor,data) VALUES(?,?,?,?)'))
local vec=assert(db:prepare('INSERT INTO slice_vec(idx,actor,embedding) VALUES(?,?,?)'))
local vector={1};for index=2,1024 do vector[index]=0 end
local embedding=assert(json.encode(vector))
for idx=1,tonumber(os.getenv('SLICES')) do
 local run=idx%2==1 and idx or idx-1
 local actor=idx%1000==0 and 'other' or 'actor'
 local data=idx%2==1 and {type='request',parent=json.null,snapshot=idx-1,value='substantial memory event '..idx,memory={}} or {type='response',source='zinc',value='recorded result '..idx}
 assert(slice:bind_values(idx,run,actor,assert(json.encode(data)))==sqlite.OK);assert(slice:step()==sqlite.DONE);slice:reset()
 assert(vec:bind_values(idx,actor,embedding)==sqlite.OK);assert(vec:step()==sqlite.DONE);vec:reset()
end
slice:finalize();vec:finalize()
assert(db:exec("UPDATE sqlite_sequence SET seq="..os.getenv('SLICES').." WHERE name='slices'; COMMIT")==sqlite.OK)
assert(db:close()==sqlite.OK)
store=require('./src/store.lua'){store='store',store_bytes=tonumber(os.getenv('STORE_BYTES'))}
local started=uv.hrtime();local tail,bytes=store:tail('actor',tonumber(os.getenv('SLICES')),tonumber(os.getenv('STORE_BYTES')));local tailMs=(uv.hrtime()-started)/1000000
local timings={}
for iteration=1,20 do
 started=uv.hrtime()
 local nearest=store:nearest(vector,'actor',1,tonumber(os.getenv('SLICES')),32)
 local ids={};for index,item in ipairs(nearest)do ids[index]=item.idx end
 store:fetch(ids,'actor',tonumber(os.getenv('SLICES')))
 timings[iteration]=(uv.hrtime()-started)/1000000
end
store:close();return{tail=#tail,bytes=bytes,tail_ms=tailMs,timings=timings}
''', ("src/store.lua",), timeout=900, deadline="15m")
    elapsed = time.perf_counter() - started
    ordered = sorted(result["timings"])
    p95 = ordered[int(len(ordered) * 0.95) - 1]
    print(f"{SLICES:,} indexed Slices: build {elapsed:.2f}s")
    print(f"tail: {result['tail']:,} Slices / {result['bytes']:,} bytes in {result['tail_ms']:.2f}ms")
    print(f"nearest + fetch: median {statistics.median(result['timings']):.2f}ms; p95 {p95:.2f}ms")
finally:
    package.close()
