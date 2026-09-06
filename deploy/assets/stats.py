import subprocess
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Tiny HTTP wrapper around the local Xray management API.
# Docker controls external exposure. Keep the Xray gRPC/API port private.

COMMAND_TIMEOUT = float(os.environ.get("STATS_COMMAND_TIMEOUT", "4"))
if COMMAND_TIMEOUT <= 0:
    raise ValueError("STATS_COMMAND_TIMEOUT must be positive")


def run(cmd):
    """Run a bounded Xray API command and require a JSON object response."""
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=COMMAND_TIMEOUT,
        check=True,
    )
    data = json.loads(result.stdout)
    if not isinstance(data, dict):
        raise ValueError(" API response must be a JSON object")
    return data

class Handler(BaseHTTPRequestHandler):
    def send_json(self, status, data):
        body = (json.dumps(data, separators=(",", ":")) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.send_json(200, {"ok": True})
            return

        commands = {
            "/online": ["xray", "api", "statsgetallonlineusers", "--server=127.0.0.1:10085"],
            "/stats": ["xray", "api", "statsquery", "--server=127.0.0.1:10085", "--pattern", "user>>>"],
        }
        command = commands.get(self.path)
        if command is None:
            self.send_json(404, {"error": "not found"})
            return

        try:
            self.send_json(200, run(command))
        except subprocess.TimeoutExpired:
            self.send_json(504, {"error": " API timed out"})
        except (OSError, subprocess.CalledProcessError, json.JSONDecodeError, ValueError):
            self.send_json(502, {"error": " API request failed"})

    def log_message(self, *args):
        # Suppress BaseHTTPRequestHandler's per-request stderr logging; this
        # endpoint is polled often and the JSON response is the useful signal.
        pass

# Bind all interfaces inside the container; Docker controls external exposure.
def main():
    server = ThreadingHTTPServer((os.environ.get("STATS_LISTEN", "0.0.0.0"), 9091), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
