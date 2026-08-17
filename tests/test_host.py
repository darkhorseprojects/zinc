import os

from support import Package


def test_files_are_exact_complete_and_atomic():
    package = Package()
    try:
        outside = package.root / "outside.txt"
        outside.write_text("outside")
        package.environment["WORK"] = str(package.work)
        package.environment["OUTSIDE"] = str(outside)
        value = package.lua(r'''
local host=require('src.host').new{
 Guide='guide',Files={{root=os.getenv('WORK'),access='read-write'}},HTTP={},Commands={},Variables={}
}
host.files.write{path='value.txt',content='one\ntwo\nthree\n'}
local complete=host.files.read{path='value.txt'}
local selected=host.files.read{path='value.txt',offset=2,limit=1}
host.files.edit{path='value.txt',edits={{oldText='two',newText='changed'}}}
local edited=host.files.read{path='value.txt'}
local ambiguous=pcall(host.files.edit,{path='value.txt',edits={{oldText='e',newText='x'}}})
local outside=pcall(host.files.read,{path=os.getenv('OUTSIDE')})
return{guide=host.guide,complete=complete,selected=selected,edited=edited,ambiguous=ambiguous,outside=outside}
''', ("src.host",))
        assert value == {
            "guide": "guide", "complete": "one\ntwo\nthree\n", "selected": "two",
            "edited": "one\nchanged\nthree\n", "ambiguous": False, "outside": False,
        }
    finally:
        package.close()


def test_edit_preserves_existing_permissions_and_failed_edits_leave_files_unchanged():
    if os.name == "nt":
        return
    package = Package()
    try:
        executable = package.work / "executable.txt"
        ordinary = package.work / "ordinary.txt"
        executable.write_text("old executable", encoding="utf-8")
        ordinary.write_text("old ordinary", encoding="utf-8")
        executable.chmod(0o755)
        ordinary.chmod(0o644)
        package.environment["WORK"] = str(package.work)
        value = package.lua(r'''
local files=require('src.host').new{
 Guide='guide',Files={{root=os.getenv('WORK'),access='read-write'}},HTTP={},Commands={},Variables={}
}.files
files.edit{path='executable.txt',edits={{oldText='old',newText='new'}}}
files.edit{path='ordinary.txt',edits={{oldText='old',newText='new'}}}
local failed=pcall(files.edit,{path='ordinary.txt',edits={{oldText='missing',newText='bad'}}})
return{executable=files.read{path='executable.txt'},ordinary=files.read{path='ordinary.txt'},failed=failed}
''', ("src.host",))
        assert value == {"executable": "new executable", "ordinary": "new ordinary", "failed": False}
        assert executable.stat().st_mode & 0o777 == 0o755
        assert ordinary.stat().st_mode & 0o777 == 0o644
    finally:
        package.close()


def test_processes_use_argument_vectors_and_selected_environment():
    package = Package()
    try:
        package.environment["KEEP"] = "visible"
        package.environment["SECRET"] = "hidden"
        value = package.lua(r'''
local host=require('src.host').new{
 Guide='guide',Files={},HTTP={},Variables={{name='KEEP'}},Commands={{
  name='print',program='python',arguments=[=[["-c","import os,sys;print('<'+sys.argv[1]+'>|'+os.getenv('KEEP','')+':'+os.getenv('SECRET','unset'),end='')","{{value}}"]]=],directory='.'
 }}
}
local hostile='$(printf injected); *; value with spaces'
local result=host.run{name='print',values={value=hostile}}
local missing=pcall(host.run,{name='print',values={}})
local extra=pcall(host.run,{name='print',values={value='x',other='y'}})
return{stdout=result.stdout,status=result.status,missing=missing,extra=extra}
''', ("src.host",))
        assert value == {"stdout": "<$(printf injected); *; value with spaces>|visible:unset", "status": 0,
                         "missing": False, "extra": False}
    finally:
        package.close()
