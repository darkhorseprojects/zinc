#!/usr/bin/env python3
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from support import Package


class Server(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/redirect":
            self.send_response(302); self.send_header("location", "/value"); self.end_headers(); return
        body = b"x" * 2000 if self.path == "/large" else b"network"
        self.send_response(200); self.send_header("x-value", "header"); self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *_):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Server)
thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
package = Package()
try:
    outside = package.root / "outside.txt"; outside.write_text("outside")
    (package.work / "escape").symlink_to(outside)
    package.environment.update({"WORK": str(package.work), "ORIGIN": f"http://127.0.0.1:{server.server_port}", "VALUE": "delegated"})
    value = package.lua(r'''
local document={Environment={Guide='guide',Files={{root=os.getenv('WORK'),access='read-write'}},HTTP={{origin=os.getenv('ORIGIN')}},Shell={{header='inspect'}}}}
local env=require('./src/env.lua')({store_bytes=1024},document)
env.files.write('value.txt','zinc')
local oversizedWrite=pcall(env.files.write,'value.txt',string.rep('x',1025))
local read=env.files.read('value.txt')
local listed=env.files.list('.')
local escaped=pcall(env.files.read,'escape')
local denied=pcall(env.http,{url='https://example.com/'})
local response=env.http{url=os.getenv('ORIGIN')..'/value'}
local redirect=env.http{url=os.getenv('ORIGIN')..'/redirect'}
local large=pcall(env.http,{url=os.getenv('ORIGIN')..'/large'})
local shell=env.shell('inspect','printf "$VALUE"; printf problem >&2; exit 7')
local shellLimit=pcall(env.shell,'inspect','head -c 1025 /dev/zero')
local shellCombined=pcall(env.shell,'inspect','head -c 600 /dev/zero; head -c 600 /dev/zero >&2')
local badHeader=pcall(env.shell,'other','true')
return {guide=env.guide,read=read,listed=listed,escaped=escaped,denied=denied,oversizedWrite=oversizedWrite,status=response.status,header=response.headers['x-value'],body=response.body,redirect=redirect.status,large=large,shell=shell,shellLimit=shellLimit,shellCombined=shellCombined,badHeader=badHeader}
''', ("src/env.lua",))
    assert value["guide"] == "guide" and value["read"] == "zinc" and "value.txt" in value["listed"]
    assert all(value[name] is False for name in ("escaped", "denied", "oversizedWrite", "large", "shellLimit", "shellCombined", "badHeader")), value
    assert (value["status"], value["header"], value["body"], value["redirect"]) == (200, "header", "network", 302)
    assert value["shell"] == {"status": 7, "signal": 0, "stdout": "delegated", "stderr": "problem"}
finally:
    package.close(); server.shutdown(); server.server_close(); thread.join(timeout=5)
print("ok environment")
