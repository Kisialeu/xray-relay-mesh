# Inventory examples

This folder contains sample `inventory.json` files for `mesh.sh`.

- `inventory.2node.json`: minimal 2-node mesh
- `inventory.3node.json`: 3-node mesh

Use one of them as the base for your real `inventory.json`.

## How to create your inventory

From the repo root:

```bash
cp configs/examples/inventory.2node.json configs/inventory.json
```

Or start from the 3-node version:

```bash
cp configs/examples/inventory.3node.json configs/inventory.json
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
- `content_deploy_dir`: optional separate remote root for managed subscription content; defaults to `<caddy_deploy_dir>-content`
- `ssh_user`: SSH user for the Caddy host
- `ssh_key`: SSH private key path for the Caddy host
- `sub_secret`: secret used to build private subscription URLs
- Optional INCY metadata: `profile_title`, `profile_description`, `support_url`,
  `support_email`, and `profile_update_interval` under `subs`.
- Optional INCY application routing: `app_proxy.enable`, `app_proxy.mode`, and
  `app_proxy.packages`. Disabled by default.
- `origin_verify_secret`: secret header value used between CloudFront and Caddy

`hysteria`

- Shared Hysteria2 (apernet/hysteria) settings for every node that opts in - see the `hysteria` entry in each node's `protocols` below. Not a mesh-wide switch: it's still off on any node that doesn't list `"hysteria"` in `protocols`.
- `acme_email`: Let's Encrypt account email; required as soon as any node opts in
- `masquerade_url`: what a non-authenticated/probing connection is proxied to; defaults to `https://<xray.reality.sni>` if left empty
- `up_mbps`, `down_mbps`: bandwidth limits advertised to clients
- `obfs_password`: optional Salamander obfuscation password, shared across every Hysteria-enabled node
- `stats_port`: internal `trafficStats` API port (default `9999`); reached over the Xray container's own Docker network, never exposed on the host

`xray`

- Shared Xray settings for all nodes.

`xray.reality`

- `private_key`, `public_key`: shared Reality keys for all nodes
- `short_id`: Reality short ID
- `sni`: Reality server name

Both keys must exist before deployment. Deployment validates them but never generates or changes them.

`xray.dns`

- DNS servers used inside the Xray stack. Hysteria uses `dns1` as its UDP resolver.

`xray.users`

- List of subscription users.
- `uuid`: client UUID
- `email`: user label used in generated links
- `hidden_nodes`: optional per-user node filter. The existing list form, such
  as `["node-a"]`, hides every protocol and relay link involving those nodes.
  The object form hides selected protocols, for example
  `{"node-a": "hysteria"}`. Object values may be `"all"`, `"xray"`,
  `"hysteria"`, or a list such as `["xray", "hysteria"]`. Hiding `xray` also
  removes relay links involving that node.
- `subscription_access`: optional subscription visibility policy. Set `default`
  to `"deny"` for an allowlist or `"allow"` for a denylist. Direct rules require
  `path`, `protocol`, and `node`. Relay rules require `path`, `entry`, and
  `destination`; the entry node must have `is_relay_entry: true`. Rules in
  `deny` take precedence over rules in `allow`.

Example 1 - expose only Swiss over direct TCP:

```json
"subscription_access": {
  "default": "deny",
  "allow": [
    {"path": "direct", "protocol": "xray", "node": "swiss"}
  ]
}
```

Example 2 - expose Astana over direct TCP and UDP:

```json
"subscription_access": {
  "default": "deny",
  "allow": [
    {"path": "direct", "protocol": "xray", "node": "astana"},
    {"path": "direct", "protocol": "hysteria", "node": "astana"}
  ]
}
```

Example 3 - expose Swiss TCP, Astana UDP, and the relay to Helsinki through
Astana:

```json
"subscription_access": {
  "default": "deny",
  "allow": [
    {"path": "direct", "protocol": "xray", "node": "swiss"},
    {"path": "direct", "protocol": "hysteria", "node": "astana"},
    {"path": "relay", "entry": "astana", "destination": "helsinki"}
  ]
}
```

This policy changes generated subscriptions only. It does not change server-side
credentials or protocol authorization.

Validate the inventory and preview the exact profile labels visible to each
user without printing connection URLs, hosts, or UUIDs:

```bash
./mesh.sh subscription access --inventory configs/inventory.json
```

The same report is available under `Subscriptions and Caddy` in the interactive
UI. The underlying script remains directly executable at
`bashbuild/scripts/subscription-access-report.sh`.

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
- `protocols`: optional list of protocols this node runs; defaults to `["xray"]`, add `"hysteria"` to also run Hysteria2
- `tls_domain`: required if `protocols` includes `"hysteria"` - a real DNS name pointing at this node's `host`, used for its Hysteria2 ACME certificate
- `hysteria_stats_secret`: required if `protocols` includes `"hysteria"` - must be the same value on every Hysteria-enabled node

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

### Reality and Hysteria secrets

Provision the Reality keypair before deployment. If Hysteria is enabled, set
the same `hysteria_stats_secret` value on every Hysteria-enabled node. The
framework never generates, rotates, or normalizes inventory secrets.

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
./mesh.sh deploy xray
./mesh.sh deploy relay
./mesh.sh deploy caddy
./mesh.sh deploy subscriptions
```
