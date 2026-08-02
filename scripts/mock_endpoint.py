#!/usr/bin/env python3
"""Tiny mock of the location-ingest server, for the simulator test. Logs every
received POST body to a file so the CI can assert the app sent a well-formed
location payload. Mirrors the real server's /overland contract.

The Authorization scheme is logged alongside the body because the real server
rejects on auth, and a mock that accepts everything cannot see that. A build
that captured points, posted them, and carried no Authorization header looked
completely green here while the real server answered 401 auth=none.
"""
import http.server
import json
import sys

LOG = sys.argv[1] if len(sys.argv) > 1 else "/tmp/received.log"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8399


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace")
        header = self.headers.get("Authorization", "")
        # Scheme only, never the credential.
        scheme = header.split(" ")[0] if header else "none"
        with open(LOG, "a") as f:
            f.write(f"POST {self.path} auth={scheme}\n{body}\n---\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"result":"ok"}')

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    open(LOG, "w").close()
    http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
