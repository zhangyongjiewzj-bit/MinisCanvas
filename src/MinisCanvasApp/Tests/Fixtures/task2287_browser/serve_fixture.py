#!/usr/bin/python3 -IS
"""Finite loopback fixture: exact GET routes only, no uploads or filesystem traversal."""
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlsplit
import sys
import hashlib
ROOT = Path(__file__).resolve().parent
ROUTES = {"/index.html": ("index.html", "text/html; charset=utf-8"),
          "/synthetic.txt": ("synthetic.txt", "text/plain; charset=utf-8")}
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        item = ROUTES.get(path)
        if item is None:
            self.send_error(404)
            return
        filename, mime = item
        data = (ROOT / filename).read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'none'; form-action 'self'; base-uri 'none'")
        self.end_headers()
        self.wfile.write(data)
    def do_POST(self):
        # Do not parse, read or store request bodies, even synthetic ones.
        self.send_error(405, "Fixture uploads are disabled")
    def log_message(self, fmt, *args):
        print("TASK2287_LOCAL " + fmt % args, flush=True)
if __name__ == "__main__":
    if sys.argv[1:] == ["--verify"]:
        for name in ["index.html", "synthetic.txt", "upload-synthetic.txt"]:
            data = (ROOT / name).read_bytes()
            assert len(data) <= 16384
            print("TASK2287_FILE " + name + " SHA256=" + hashlib.sha256(data).hexdigest())
        print("TASK2287_LOCAL_VERIFY_OK; listener NOT_STARTED")
        raise SystemExit(0)
    if sys.argv[1:]:
        raise SystemExit("usage: serve_fixture.py [--verify]")
    with HTTPServer(("127.0.0.1", 22871), Handler) as server:
        print("TASK2287_LOCAL_READY http://127.0.0.1:22871/index.html", flush=True)
        server.serve_forever()
