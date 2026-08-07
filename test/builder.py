#!/usr/bin/env python3
from support import Package

package = Package()
try:
    value = package.lua(r'''
local builder=require('./builder.lua')(require('./docs.md'))
local questionnaire=builder:questionnaire('Build a release Agent')
local files=builder:template{name='Release',instructions='Prepare a reviewed release.',program='return args.input'}
return {guide=builder.guide,questionnaire=questionnaire,entry=files['agent.md']}
''')
    assert value["questionnaire"]["goal"] == "Build a release Agent"
    questions = value["questionnaire"]["questions"]
    assert any("confirmation" in question for question in questions)
    assert any("ideal response" in question for question in questions)
    assert "# Release" in value["entry"] and "## Program" in value["entry"]
    assert "Begin with the job" in value["guide"]
finally:
    package.close()
print("ok builder")
