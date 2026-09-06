# Inventory examples

This folder contains sample `inventory.json` files for `mesh.sh`.

- [inventory.2node.json](/Users/siarhei/Sources/xray-relay-mesh/examples/inventory.2node.json): minimal 2-node mesh
- [inventory.3node.json](/Users/siarhei/Sources/xray-relay-mesh/examples/inventory.3node.json): 3-node mesh

Use one of them as the base for your real `inventory.json`.

## How to create your inventory

From the repo root:

```bash
cp examples/inventory.2node.json inventory.json
```

Or start from the 3-node version:

```bash
cp examples/inventory.3node.json inventory.json
```

Then edit `inventory.json` and replace the example values.

## Parameter guide

### Top level

`relay_port_base`

- Base port for relay listeners.
- Real relay port for a node is `relay_port_base + node.id`.
- Keep it clear of any `direct_port` values used by other nodes.

`resolvers`

- DNS settings used in rendered HAProxy configs.
- `dns1`, `dns2`: upstream resolvers
- `hold_valid`: HAProxy DNS cache duration

`stats`

- Settings for central stats polling.
- `node_port`: node-local stats HTTP port, bound to `127.0.0.1`
- `public_port`: public HAProxy stats port
- `web_port`: Nginx frontend host-loopback port on the master node
- `app_port`: Flask/Waitress stats backend host-loopback port on the master node
- `master_node`: node that runs the central stats app and Postgres
- `expose_via_haproxy`: whether relay HAProxy exposes authenticated stats
- `ssh_user`: dedicated account used by the central stats service to poll nodes
- `ssh_port`: SSH port used for stats polling
- `token`: required `X-Stats-Token` value for HAProxy stats access
- `allowed_sources`: optional list of central stats host source CIDRs allowed by HAProxy
- `postgres_port`, `postgres_password`: Postgres sidecar settings on the master node
- `rate_limit_period`, `rate_limit_requests`: per-source HAProxy request limit

`subs`

- Settings for subscription publishing and the Caddy host.
- `domain`: public subscription domain, for example `sub.example.com`
- `zone_domain`: Route53 hosted zone, for example `example.com`
- `caddy_host`: server that runs Caddy and serves subscription files
- `caddy_deploy_dir`: remote deployment directory for Caddy
- `ssh_user`: SSH user for the Caddy host
- `ssh_key`: SSH private key path for the Caddy host
- `sub_secret`: secret used to build private subscription URLs
- `origin_verify_secret`: secret header value used between CloudFront and Caddy

`xray`

- Shared Xray settings for all nodes.

`xray.reality`

- `private_key`, `public_key`: shared Reality keys for all nodes
- `short_id`: Reality short ID
- `sni`: Reality server name

If `private_key` and `public_key` are left empty, `./mesh.sh deploy-nodes` can generate them automatically and save them back into `inventory.json`.

`xray.dns`

- DNS servers used inside the Xray stack.

`xray.users`

- List of subscription users.
- `uuid`: client UUID
- `email`: user label used in generated links
- `hidden_nodes`: optional list of node names hidden from that user

`nodes`

- List of mesh nodes.

Each node has:

- `id`: unique permanent numeric ID
- `name`: unique short name, for example `frankfurt`
- `friendly_name`: human-readable label, for example `Germany`
- `host`: SSH hostname or IP
- `direct_port`: Xray listening port on that host, usually `443`
- `ssh_user`: SSH user for that node
- `ssh_key`: SSH private key path for that node
- `is_relay_entry`: whether this node should be used as a curated relay entry in generated subscriptions

## How to create values

### Node IDs

- Start at `1` and increment for each node.
- Do not reuse old IDs after removing a node.

Example:

```json
"nodes": [
  { "id": 1, "name": "suomi", "host": "suomi.example.com", "direct_port": 443, "ssh_user": "root", "ssh_key": "~/.ssh/my_custom_key", "is_relay_entry": true },
  { "id": 2, "name": "frankfurt", "host": "frankfurt.example.com", "direct_port": 443, "ssh_user": "root", "ssh_key": "~/.ssh/my_custom_key", "is_relay_entry": false }
]
```

### User UUIDs

Generate a UUID locally:

```bash
uuidgen
```

Then place it into `xray.users`:

```json
{ "uuid": "PUT-UUID-HERE", "email": "demo_user" }
```

### Secrets

Generate `sub_secret` and `origin_verify_secret` locally:

```bash
openssl rand -hex 20
```

Use different values for each secret.

### Reality keys

Two options:

1. Leave them empty and let `./mesh.sh deploy-nodes` generate them.
2. Set them manually if you already have a known Reality keypair.

## Minimal checklist

Before first deploy, make sure you changed:

- all example hostnames
- all SSH users and key paths
- `subs.domain`
- `subs.zone_domain`
- `subs.caddy_host`
- `subs.sub_secret`
- `subs.origin_verify_secret`
- every user UUID

## Typical flow

```bash
./mesh.sh
```

Or scripted:

```bash
./mesh.sh deploy-nodes
./mesh.sh deploy-relay-all
./mesh.sh deploy-caddy
./mesh.sh subs-generate
./mesh.sh subs-sync
```
