#!/usr/bin/env python3
import sqlite3
from support import Zinc

zinc = Zinc()
try:
    value = zinc.value(r'''
local d=require('@database')(require('@authority'))
local run=d.newRun(nil,'opaque-actor')
local first=d.append(run,'request',{message='writes are allowed',secretkeyword='ordinary'})
local second=d.append(run,'zinc',{message='policy follows the writing rule'})
d.trail(second,{first})
local recalled=d.recall('writing allowed',d.snapshot(),999,{})
local polluted=d.recall('secretkeyword',d.snapshot(),999,{})
local huge=d.append(run,'circuitry',{text=string.rep('x',40000)})
local recent=d.recent(d.snapshot(),999,65536)
local bounded=recent[#recent].value
require('@authority').os.remove(bounded.overflow)
local ok,failure=pcall(d.read,huge)
d.complete(run,'done')
return {first=first,second=second,recall=#recalled,polluted=#polluted,bounded=#bounded.tail<40000,missing=(not ok and failure:find('current continuation payload is unavailable',1,true)~=nil),result=d.result(run)}
''')
    assert value == {
        "first": 1,
        "second": 2,
        "recall": 2,
        "polluted": 0,
        "bounded": True,
        "missing": True,
        "result": "done",
    }, value
    persisted = zinc.value("local d=require('@database')(require('@authority')); return {snapshot=d.snapshot(),value=d.read(1).message}")
    assert persisted == {"snapshot": 3, "value": "writes are allowed"}, persisted
    connection = sqlite3.connect(zinc.database)
    assert connection.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
    assert connection.execute("SELECT actor FROM runs").fetchone()[0] == "opaque-actor"
    assert connection.execute("SELECT count(*) FROM sqlite_master WHERE name IN ('slice_words','slice_trigrams')").fetchone()[0] == 2
    connection.close()
finally:
    zinc.close()
print("ok database")
