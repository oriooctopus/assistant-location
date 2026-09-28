#!/usr/bin/env python3
# Test-only: serves Modules/WebPages/ the way events/server.py does
# (GET /webpages/manifest.json, GET /webpages/files/<name>) on :8304.
import hashlib, http.server, json, os, sys, time
DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Modules", "WebPages")

def manifest():
    files = {}
    for name in sorted(os.listdir(DIR)):
        p = os.path.join(DIR, name)
        if not os.path.isfile(p): continue
        data = open(p, "rb").read()
        files[name] = {"hash": "sha256:" + hashlib.sha256(data).hexdigest(), "size": len(data)}
    vin = "\n".join(f"{n}:{i['hash']}" for n, i in sorted(files.items()))
    return {"version": hashlib.sha256(vin.encode()).hexdigest(), "files": files}

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        print(f"{time.time():.1f} GET {self.path}", flush=True)
        if self.path == "/webpages/manifest.json":
            body, ct = json.dumps(manifest()).encode(), "application/json"
        elif self.path.startswith("/webpages/files/"):
            p = os.path.join(DIR, os.path.basename(self.path))
            if not os.path.isfile(p):
                self.send_error(404); return
            body, ct = open(p, "rb").read(), "application/octet-stream"
        else:
            self.send_error(404); return
        self.send_response(200)
        self.send_header("Content-Type", ct); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass

http.server.ThreadingHTTPServer(("127.0.0.1", 8304), H).serve_forever()
