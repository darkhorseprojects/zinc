#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "test"))
from support import Zinc

zinc = Zinc()
try:
    value = zinc.value(r'''
local database=require('@database')(require('@authority'))
local clock=require('@authority').os.clock
local run=database.newRun(nil,'benchmark')
local started=clock()
for index=1,1000 do
   local text=index==417 and 'Policies permit writing files after explicit approval' or 'Unrelated memory slice number '..index
   database.append(run,'request',{message=text})
end
local append=(clock()-started)*1000
started=clock()
local recalled=database.recall('write file approval',database.snapshot(),999,{})
local recall=(clock()-started)*1000
database.complete(run,'done')
return {append_ms=append,recall_ms=recall,recalled=#recalled,first=recalled[1] and recalled[1].idx}
''')
    print(f"append 1,000 slices              {value['append_ms']:.1f} ms")
    print(f"Porter recall over 1,000 slices {value['recall_ms']:.1f} ms ({value['recalled']} recalled, first={value['first']})")
finally:
    zinc.close()
