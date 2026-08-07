#!/usr/bin/env python3
from support import Package

package = Package()
try:
    value = package.lua(r'''
local format=require('./format-discord.lua')
local result=format{role='assistant',content='final message'}
local empty=pcall(format,{role='assistant',content=''})
local oversized=pcall(format,{role='assistant',content=string.rep('é',2001)})
local unicode=pcall(format,{role='assistant',content=string.rep('é',2000)})
local invalid=pcall(format,{role='assistant',content=string.char(255)})
return {result=result,empty=empty,oversized=oversized,unicode=unicode,invalid=invalid}
''')
    assert value == {"result": "final message", "empty": False, "oversized": False, "unicode": True, "invalid": False}
finally:
    package.close()
print("ok format-discord")
