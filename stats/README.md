# Central Stats Service

This service polls node-local Xray stats through each node's HAProxy endpoint and serves a small HTML UI plus JSON API.

Node access model:

```text
central stats service -> http://<node.host>:9092/stats
central stats service -> http://<node.host>:9092/online
```

Topology:

```text
node A xray container
  127.0.0.1:9091 stats wrapper
  HAProxy public :9092 with X-Stats-Token and rate limiting
        |
        | public internet, authenticated
        v
central stats service
        ^
        | public internet, authenticated
        |
node B xray container
  127.0.0.1:9091 stats wrapper
  HAProxy public :9092 with X-Stats-Token and rate limiting
```

The Xray stats wrapper stays bound to host loopback. HAProxy is the only public stats entrypoint.

Required inventory fields:

```json
{
  "stats": {
    "node_port": 9091,
    "public_port": 9092,
    "web_port": 9093,
    "master_node": "suomi",
    "expose_via_haproxy": true,
    "token": "replace-with-random-secret",
    "allowed_sources": ["203.0.113.10/32"],
    "postgres_port": 55432,
    "postgres_password": "replace-with-random-secret",
    "rate_limit_period": "60s",
    "rate_limit_requests": 60
  },
  "nodes": [
    {
      "name": "suomi",
      "host": "37.27.24.71"
    }
  ]
}
```

Deploy to `stats.master_node` with Docker and Postgres:

```bash
./mesh.sh deploy-stats
```

Open the deployed UI through an SSH tunnel:

```bash
./mesh.sh stats
```

The command prints the local URL and keeps the tunnel open until `Ctrl-C`.

Run locally without Docker for development:

```bash
STATS_API_TOKEN="$(openssl rand -hex 24)" ./stats/run_stats.sh ./inventory.json
```

Useful environment variables:

- `STATS_BIND`: web UI/API bind address, default `127.0.0.1`
- `STATS_WEB_PORT`: web UI/API port, default `8088`
- `STATS_API_TOKEN`: required when binding outside loopback
- `STATS_NODE_TOKEN`: token used when polling node HAProxy endpoints, default `stats.token` from inventory
- `STATS_POLL_INTERVAL`: polling interval in seconds, default `15`
- `STATS_HTTP_TIMEOUT`: per-request timeout in seconds, default `5`
- `STATS_DB`: SQLite database path, default `stats/stats.sqlite3`

Security notes:

- Do not expose node port `9091` publicly.
- Expose only HAProxy `stats.public_port`.
- Require `X-Stats-Token` on HAProxy.
- Set `stats.allowed_sources` to the central stats host public IP where possible.
- Put the central UI/API behind Caddy, mTLS, or another authenticated HTTPS boundary before exposing it publicly.
