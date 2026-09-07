import json
import os
import subprocess
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Tiny HTTP wrapper around each protocol's own local stats API. Docker
# controls external exposure - both Xray's gRPC API (127.0.0.1:10085) and
# Hysteria2's trafficStats API (private, container-network-only) stay off
# the host entirely; only this wrapper's port is published, and only to
# 127.0.0.1 (see docker-compose.xray.yml).

COMMAND_TIMEOUT = float(os.environ.get("STATS_COMMAND_TIMEOUT", "4"))
if COMMAND_TIMEOUT <= 0:
    raise ValueError("STATS_COMMAND_TIMEOUT must be positive")

HYSTERIA_STATS_SECRET = os.environ.get("HYSTERIA_STATS_SECRET", "")
HYSTERIA_STATS_PORT = os.environ.get("HYSTERIA_STATS_PORT", "")


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
        raise ValueError("API response must be a JSON object")
    return data


def fetch_hysteria(path):
    """Call hysteria's private trafficStats API over the shared docker
    network (container name "hysteria" resolves via Docker's embedded DNS
    only when that service is actually running on this node)."""
    if not HYSTERIA_STATS_SECRET or not HYSTERIA_STATS_PORT:
        raise RuntimeError("hysteria stats not configured on this node")
    req = urllib.request.Request(
        f"http://hysteria:{HYSTERIA_STATS_PORT}{path}",
        headers={"Authorization": HYSTERIA_STATS_SECRET},
    )
    with urllib.request.urlopen(req, timeout=COMMAND_TIMEOUT) as resp:
        data = json.loads(resp.read().decode())
    if not isinstance(data, dict):
        raise ValueError("hysteria API response must be a JSON object")
    return data


# One entry per protocol this node can expose stats for. Adding another
# protocol later means adding one entry here (plus a matching case in the
# SSH forced-command wrapper installed by stats/deploy_stats.sh) - routing,
# error handling, and the central poller's transport all stay unchanged.
PROTOCOLS = {
    "xray": {
        "stats": lambda: run(["xray", "api", "statsquery", "--server=127.0.0.1:10085", "--pattern", "user>>>"]),
        "online": lambda: run(["xray", "api", "statsgetallonlineusers", "--server=127.0.0.1:10085"]),
    },
    "hysteria": {
        "stats": lambda: fetch_hysteria("/traffic"),
        "online": lambda: fetch_hysteria("/online"),
    },
}


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

        parts = self.path.strip("/").split("/")
        protocol = parts[0] if parts else ""
        kind = parts[1] if len(parts) > 1 else ""
        endpoint = PROTOCOLS.get(protocol, {}).get(kind)
        if len(parts) != 2 or endpoint is None:
            self.send_json(404, {"error": "not found"})
            return

        try:
            self.send_json(200, endpoint())
        except subprocess.TimeoutExpired:
            self.send_json(504, {"error": f"{protocol} API timed out"})
        except urllib.error.URLError:
            self.send_json(502, {"error": f"{protocol} API unreachable"})
        except (OSError, subprocess.CalledProcessError, json.JSONDecodeError, ValueError, RuntimeError):
            self.send_json(502, {"error": f"{protocol} API request failed"})

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
