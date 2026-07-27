#!/usr/bin/env python3
from support import Zinc

zinc = Zinc()
try:
    value = zinc.value(r'''
local env=require('@env')
env.files.write('value.txt','zinc')
local value=env.files.read('value.txt')
local listed=env.files.list('.')
local deniedShell=pcall(env.shell,'git push origin main')
local deniedPath=pcall(env.files.read,'/etc/hosts')
env.shell('ln -s /etc/hosts linked.txt')
local deniedLink=pcall(env.files.read,'linked.txt')
require('@authority').os.remove('linked.txt')
local deniedHTTP=pcall(env.http.request,{url='https://example.com/'})
local shell=env.shell('printf zinc')
local builder=require('@builder')
local tool=[=[# Tool
```lua
local authorityOk=pcall(require,'@authority')
local databaseOk=pcall(function() return require('@database')() end)
local env=require('@env')
env.files.write('tool.txt','made')
return tostring(authorityOk)..':'..tostring(databaseOk)..':'..env.files.read('tool.txt')
```]=]
local built=builder.execute(tool)
local profile=env.profile()
env.files.remove('value.txt'); env.files.remove('tool.txt')
return {value=value,listed=listed,deniedShell=deniedShell,deniedPath=deniedPath,deniedLink=deniedLink,deniedHTTP=deniedHTTP,code=shell.code,output=shell.output,built=built,username=profile.username}
''')
    assert value["value"] == "zinc"
    assert "value.txt" in value["listed"]
    assert value["deniedShell"] is False
    assert value["deniedPath"] is False
    assert value["deniedLink"] is False
    assert value["deniedHTTP"] is False
    assert (value["code"], value["output"]) == (0, "zinc")
    assert value["built"] == "false:false:made"
    assert value["username"] == "local-operator"
    assert not zinc.root.joinpath("value.txt").exists()
finally:
    zinc.close()
print("ok environment")
