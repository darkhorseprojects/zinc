#!/usr/bin/env python3
import sqlite3
from support import Zinc

zinc = Zinc()
try:
    value = zinc.value(r'''
local create=require('@run')(require('@authority'))
local child=create({name='child',actor=function() return 'child-default' end,request=function() error('child exploded') end})
local parent=create({name='parent',actor=function() return 'parent-default' end,request=function()
   local ok,failure=pcall(child.ask,'inside')
   return {output={{type='message',content={{type='output_text',text=tostring(ok)..':'..tostring(failure):match('child exploded')}}}}},{}
end})
local top=create({name='top',actor=function() return 'top-default' end,request=function() error('top exploded') end})
local parentRun=parent.ask('outside','actor with spaces')
local topOk,topFailure=pcall(top.ask,'broken','opaque')
return {parent=parent.read(parentRun),topOk=topOk,topFailure=tostring(topFailure):match('top exploded')}
''')
    assert value == {
        "parent": "false:child exploded",
        "topOk": False,
        "topFailure": "top exploded",
    }, value
    connection = sqlite3.connect(zinc.database)
    runs = connection.execute("SELECT parent,actor,status FROM runs ORDER BY id").fetchall()
    assert runs == [
        (None, "actor with spaces", "complete"),
        (1, "actor with spaces", "discarded"),
        (None, "opaque", "failed"),
    ], runs
    assert connection.execute("SELECT count(*) FROM slices WHERE run=2").fetchone()[0] == 0
    failure = connection.execute("SELECT result FROM runs WHERE id=3").fetchone()[0]
    assert "top exploded" in failure
    connection.close()
finally:
    zinc.close()
print("ok lifecycle")
