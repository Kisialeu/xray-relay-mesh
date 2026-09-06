# Central Stats Service

This service polls node-local Xray stats through restricted SSH commands and
serves the statistics UI and JSON API. The terminal homepage and Nginx reverse
proxy are deployed separately from `web/`.

Node access model:

```text
central stats service -> SSH stats-poller@<node.host> stats
central stats service -> SSH stats-poller@<node.host> online
```

Topology:

```text
node A xray container
  127.0.0.1:9091 stats wrapper
  restricted stats-poller SSH account
        |
        | SSH on port 22
        v
central stats service
  internal /xray, /users/*, /nodes/* UI
  internal /api/* JSON API
        |
node B xray container
  127.0.0.1:9091 stats wrapper
  optional HAProxy public :9092 stats endpoint
```

The Xray stats wrapper stays bound to host loopback. Central polling uses SSH;
the optional HAProxy endpoint is not used by the central service.

Required inventory fields:

```json
{
  "stats": {
    "node_port": 9091,
    "public_port": 9092,
    "web_port": 9093,
    "app_port": 9094,
    "web_domain": "stats.example.com",
    "web_email": "admin@example.com",
    "master_node": "suomi",
    "expose_via_haproxy": true,
    "ssh_user": "stats-poller",
    "ssh_port": 22,
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

The service uses SQLAlchemy ORM for database access. On startup it creates the
fresh schema from `stats/src/models.py`; no legacy SQL migrations are applied.

Deploy the backend and Postgres to `stats.master_node` with Docker:

```bash
./mesh.sh deploy-stats
```

Reset an existing stats deployment before deploying the ORM schema. This removes
all collected history but does not touch the web or Certbot directories. Run it
only in the stats directory on the stats master:

```bash
cd /opt/xray-stats
docker compose stop stats stats-postgres
docker compose rm -f stats stats-postgres
rm -rf /opt/xray-stats/postgres
```

The PostgreSQL directory is recreated by `./mesh.sh deploy-stats`.

Deploy the separate Nginx TLS frontend after the backend. The certificate and
private key must already exist and be readable on the master host:

```bash
./mesh.sh deploy-web
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

- `STATS_BIND`: backend API bind address, default `127.0.0.1`
- `STATS_APP_PORT`: backend API port, default `8088`
- `STATS_API_TOKEN`: required when binding outside loopback
- `STATS_POLL_INTERVAL`: polling interval in seconds, default `15`
- `STATS_HTTP_TIMEOUT`: per-request timeout in seconds, default `5`
- `STATS_RETENTION_DAYS`: sample history retention, default `60`
- `STATS_ONLINE_WINDOW`: seconds since last activity to consider a user online, default `300`
- `STATS_ACTIVE_DURATION`: continuous active seconds required before online, default `60`
- `STATS_MIN_ACTIVITY_BYTES`: minimum bytes transferred during the continuous active period, default `1024`
- `STATS_SSH_USER`: restricted node account, default `stats-poller`
- `STATS_SSH_PORT`: SSH port, default `22`
- `STATS_DB`: SQLite database path, default `stats/stats.sqlite3`

The web deployment stores certificates under `/opt/xray-web/letsencrypt` and
requests and renews them through Route53 using
the AWS credentials supplied to `web/deploy_web.sh`. The existing tunnel opens
an HTTPS URL because Nginx terminates TLS on `stats.web_port`.

Security notes:

- Do not expose node port `9091` publicly.
- Expose only HAProxy `stats.public_port`.
- The deployment generates a separate master SSH key under `/opt/xray-stats/ssh`.
- The deployment appends a restricted forced-command key to each node's `stats-poller` account.

- Existing personal SSH keys are preserved.
- Keep the web listener on loopback for SSH-tunnel access, or explicitly bind Nginx to a public interface and restrict the port at the host firewall.
- The stats API token remains required for data endpoints; Nginx also rate-limits `/api/` requests.

The statistics pages are served by this backend and are exposed externally
under the authenticated `/stats/` namespace. User rows link to
`/stats/users/<user>`, which displays
aggregate traffic and a per-node breakdown from the existing `samples` table.
Backend API routes remain available at
`/stats/api/summary`, `/stats/api/nodes`, `/stats/api/users`,
`/stats/api/nodes/<node>/users`, `/stats/api/nodes/<node>/history`, and the
per-node or aggregate user history routes.

Online status requires current traffic-counter activity for at least
`STATS_ACTIVE_DURATION` seconds, at least `STATS_MIN_ACTIVITY_BYTES` transferred
during that continuous period, and a `last_seen` timestamp within
`STATS_ONLINE_WINDOW`. The raw node `/online` flag is not sufficient by itself.
