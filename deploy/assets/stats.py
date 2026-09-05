import subprocess
import json
import os
from http.server import HTTPServer, BaseHTTPRequestHandler

# Tiny HTTP wrapper around the local Xray management API.
# Docker controls external exposure. Keep the Xray gRPC/API port private.

def run(cmd):
    # Xray's CLI prints JSON on success. Return an empty object if the command
    # fails or emits non-JSON output so the HTTP endpoint stays well-formed.
    r = subprocess.run(cmd, capture_output=True, text=True)
    try:
        return json.loads(r.stdout)
    except Exception:
        return {}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            body = b'{"ok":true}\n'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", len(body))
            self.end_headers()
            self.wfile.write(body)
            return

        # /online returns the currently online users; every other path returns
        # cumulative user traffic counters matching Xray's "user>>>" stat names.
        if self.path == "/online":
            data = run(["xray", "api", "statsgetallonlineusers", "--server=127.0.0.1:10085"])
        else:
            data = run(["xray", "api", "statsquery", "--server=127.0.0.1:10085", "--pattern", "user>>>"])

        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        # Suppress BaseHTTPRequestHandler's per-request stderr logging; this
        # endpoint is polled often and the JSON response is the useful signal.
        pass

# Bind all interfaces inside the container; Docker controls external exposure.
HTTPServer((os.environ.get("STATS_LISTEN", "0.0.0.0"), 9091), Handler).serve_forever()
