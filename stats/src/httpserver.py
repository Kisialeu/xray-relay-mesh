import hmac
import json
from http.server import BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

from config import API_TOKEN
from queries import rows, summary


def authorized(handler):
    if not API_TOKEN:
        return True
    parsed = urlparse(handler.path)
    candidates = [parse_qs(parsed.query).get("token", [""])[0]]
    header_token = handler.headers.get("X-Stats-Token", "")
    if header_token:
        candidates.append(header_token)
    auth = handler.headers.get("Authorization", "")
    if auth.startswith("Bearer "):
        candidates.append(auth[len("Bearer "):])
    return any(hmac.compare_digest(c, API_TOKEN) for c in candidates if c)


def html():
    return """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Xray Stats</title>
<style>
body{font-family:system-ui,-apple-system,Segoe UI,sans-serif;margin:0;background:#f7f7f4;color:#171717}
main{max-width:1180px;margin:0 auto;padding:24px}
h1{font-size:24px;margin:0 0 20px}
section{margin:0 0 24px}
table{width:100%;border-collapse:collapse;background:white;border:1px solid #ddd}
th,td{text-align:left;padding:10px;border-bottom:1px solid #eee;font-size:14px}
th{background:#efefea;font-weight:650}
.ok{color:#116329}.bad{color:#a12121}.muted{color:#666}
</style>
</head>
<body>
<main>
<h1>Xray Stats</h1>
<section><h2>Nodes</h2><table id="nodes"></table></section>
<section><h2>Users</h2><table id="users"></table></section>
</main>
<script>
const qs = new URLSearchParams(location.search);
const token = qs.get("token") || localStorage.getItem("stats_token") || "";
if (token) localStorage.setItem("stats_token", token);
function bytes(n){if(!n)return "0 B"; const u=["B","KB","MB","GB","TB"]; let i=0; while(n>=1024&&i<u.length-1){n/=1024;i++} return n.toFixed(i?2:0)+" "+u[i]}
function date(ts){return ts ? new Date(ts*1000).toLocaleString() : ""}
function esc(s){return String(s ?? "").replace(/[&<>"']/g, c => {
  switch(c){case "&": return "&amp;"; case "<": return "&lt;"; case ">": return "&gt;"; case '"': return "&quot;"; default: return "&#39;"}
})}
async function load(){
  const url = token ? "/api/summary?token="+encodeURIComponent(token) : "/api/summary";
  const r = await fetch(url);
  if(!r.ok){document.body.textContent="Unauthorized or unavailable"; return}
  const data = await r.json();
  nodes.innerHTML = "<tr><th>Node</th><th>Status</th><th>Latency</th><th>Error</th><th>Updated</th></tr>" +
    data.nodes.map(n=>`<tr><td>${esc(n.node)}</td><td class="${n.ok?"ok":"bad"}">${n.ok?"ok":"down"}</td><td>${n.latency_ms} ms</td><td class="muted">${esc(n.error||"")}</td><td>${date(n.ts)}</td></tr>`).join("");
  users.innerHTML = "<tr><th>User</th><th>Node</th><th>Total</th><th>Up</th><th>Down</th><th>Online</th><th>Active</th><th>Last Seen</th></tr>" +
    data.users.map(u=>`<tr><td>${esc(u.user)}</td><td>${esc(u.node)}</td><td>${bytes(u.total)}</td><td>${bytes(u.uplink)}</td><td>${bytes(u.downlink)}</td><td>${u.online?"yes":"no"}</td><td>${u.active?"yes":"no"}</td><td>${date(u.last_seen)}</td></tr>`).join("");
}
load(); setInterval(load, 5000);
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def send_json(self, status, data):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/":
            body = html().encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path == "/api/health":
            self.send_json(200, {"ok": True})
            return
        if parsed.path.startswith("/api/") and not authorized(self):
            self.send_json(401, {"error": "unauthorized"})
            return
        if parsed.path == "/api/summary":
            self.send_json(200, summary())
            return
        if parsed.path == "/api/nodes":
            self.send_json(200, rows("select * from health order by node"))
            return
        if parsed.path == "/api/users":
            self.send_json(200, summary()["users"])
            return
        self.send_json(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        return
