#!/usr/bin/env python3
import sqlite3
from support import Zinc

zinc = Zinc()
try:
    value = zinc.value(r'''
local create=require('@run')(require('@authority'))
local function message(text) return {output={{type='message',content={{type='output_text',text=text}}}}},{} end
local child=create({name='child',actor=function() return 'child-default' end,request=function(actor,current) return message('child:'..actor..':'..current[1].value) end})
local mergedReference, discardedReference
local parent=create({name='parent',actor=function() return 'parent-default' end,request=function(actor,current)
   mergedReference=child.ask('inside')
   local childValue=child.read(mergedReference)
   child.merge(mergedReference)
   discardedReference=child.ask('forgotten','other-opaque')
   child.discard(discardedReference)
   return message('parent:'..actor..':'..childValue)
end})
local fields={}
for name in pairs(parent) do fields[#fields+1]=name end
table.sort(fields)
local reference=parent.ask('outside','123456789012345678')
local invalidMerged=pcall(child.read,mergedReference)
local invalidDiscarded=pcall(child.read,discardedReference)
return {fields=fields,result=parent.read(reference),invalidMerged=invalidMerged,invalidDiscarded=invalidDiscarded}
''')
    assert value == {
        "fields": ["ask", "discard", "merge", "name", "read"],
        "result": "parent:123456789012345678:child:123456789012345678:inside",
        "invalidMerged": False,
        "invalidDiscarded": False,
    }, value
    connection = sqlite3.connect(zinc.database)
    runs = connection.execute("SELECT parent,actor,status FROM runs ORDER BY id").fetchall()
    assert runs == [
        (None, "123456789012345678", "complete"),
        (1, "123456789012345678", "merged"),
        (1, "other-opaque", "discarded"),
    ], runs
    assert connection.execute("SELECT count(*) FROM slices WHERE run=3").fetchone()[0] == 0
    assert connection.execute("SELECT result FROM runs WHERE id=1").fetchone()[0] is not None
    connection.close()
    assert list(zinc.state.glob("*.sqlite3")) == [zinc.database]
finally:
    zinc.close()
print("ok run")
