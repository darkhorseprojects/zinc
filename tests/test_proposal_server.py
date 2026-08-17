import http.client
import importlib.util
import pathlib
import threading
import time
from http.server import BaseHTTPRequestHandler

ROOT = pathlib.Path(__file__).resolve().parents[1]
path = ROOT / "tools/proposals.py"
spec = importlib.util.spec_from_file_location("proposal_server", path)
module = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(module)


class BlockingHandler(BaseHTTPRequestHandler):
    entered = threading.Event()
    release = threading.Event()
    active = 0
    maximum = 0
    lock = threading.Lock()

    def do_GET(self):
        with self.lock:
            type(self).active += 1
            type(self).maximum = max(type(self).maximum, type(self).active)
        type(self).entered.set()
        type(self).release.wait(5)
        with self.lock:
            type(self).active -= 1
        self.send_response(200)
        self.send_header("content-length", "0")
        self.end_headers()

    def log_message(self, *_):
        pass


def test_bounded_server_never_exceeds_concurrency():
    BlockingHandler.entered.clear()
    BlockingHandler.release.clear()
    BlockingHandler.active = BlockingHandler.maximum = 0
    server = module.BoundedThreadingHTTPServer(("127.0.0.1", 0), BlockingHandler, 2)
    serving = threading.Thread(target=server.serve_forever, daemon=True)
    serving.start()
    failures = []

    def request():
        try:
            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
            connection.request("GET", "/")
            response = connection.getresponse()
            response.read()
            connection.close()
        except Exception as error:
            failures.append(error)

    clients = [threading.Thread(target=request) for _ in range(4)]
    for client in clients:
        client.start()
    assert BlockingHandler.entered.wait(2)
    time.sleep(0.1)
    assert BlockingHandler.maximum == 2
    BlockingHandler.release.set()
    for client in clients:
        client.join(5)
    server.shutdown()
    server.server_close()
    serving.join(5)
    assert not failures
    assert BlockingHandler.maximum == 2
