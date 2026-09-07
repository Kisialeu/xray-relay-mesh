# xray-relay-mesh

`xray-relay-mesh` is a Bash-based deployment framework for a small Xray mesh:

- `bashbuild/` owns deployment orchestration and reusable Bash primitives
- `services/` contains runtime service payloads without remote orchestration
- `infrastructure/` contains explicit host and AWS lifecycle operations
- `configs/` contains ignored operator configuration and committed examples
- `mesh.sh` is the single entrypoint for operators

The repo is inventory-driven. You describe nodes, users, relay ports, and subscription settings in `configs/inventory.json`, then render and deploy from there.

## What it manages

Each node can run three layers:

1. Xray on that node's own `direct_port`
2. HAProxy listeners for every other node in the mesh, using deterministic relay ports derived from `relay_port_base + node.id`
3. Optionally, Hysteria2 (a separate UDP/QUIC server, not an Xray protocol) on the same port number as `direct_port` but UDP - direct-connect only, no HAProxy relay (HAProxy here is TCP passthrough only)

Separately, one Caddy host serves generated subscription files. That host can optionally sit behind CloudFront with a custom origin verification header.

## Repository layout

```text
mesh.sh                      Stable launcher
bashbuild/                   Bash framework, CLI, primitives, controllers
services/                    Runtime service source, images, and templates
infrastructure/              Host lifecycle and AWS/CDN provisioning
configs/                     Local inventory, schema, examples, secrets
tests/                       Offline unit, integration, and golden tests
docs/                        Operational and architecture documentation
var/                         Ignored generated runtime artifacts
```

## Requirements

Local tools used by the scripts:

- `bash`
- `jq`
- `ssh`
- `scp`
- `rsync` for subscription sync
- `curl`
- `sha256sum`
- `base64`
- `aws` CLI for explicit CDN apply and destroy operations
- `qrencode` is optional for QR outputs during subscription generation

Remote hosts:

- SSH access with the per-node `ssh_user` / `ssh_key` declared in inventory
- `sudo` on the target hosts
- Docker, Docker Compose, `zstd`, and cron; install them explicitly with `./mesh.sh bootstrap --node NAME`

## Inventory

The default inventory path is `./configs/inventory.json`. Example inventories live in:

- `configs/examples/inventory.2node.json`
- `configs/examples/inventory.3node.json`

Main sections:

- `relay_port_base`: base port used to derive relay listeners as `base + node.id`
- `resolvers`: HAProxy DNS resolver settings
- `subs`: subscription domain, Caddy host, deployment dir, SSH settings, and secrets
- `xray.reality`: shared Reality keys and SNI for all nodes
- `xray.users`: subscription users, UUIDs, and optional per-user hidden nodes - also the Hysteria2 identity/password for that same user on any node that opts in to Hysteria2
- `hysteria`: shared Hysteria2 settings (`acme_email`, `masquerade_url`, `up_mbps`/`down_mbps`) for whichever nodes opt in - see below
- `nodes`: mesh members with stable `id`, `name`, `host`, `direct_port`, SSH settings, optional `is_relay_entry`, optional `protocols` (defaults to `["xray"]`; add `"hysteria"` to also run Hysteria2 on that node), and `tls_domain` (required on any node whose `protocols` includes `"hysteria"`)

Important invariants enforced by the tooling:

- node `id` values must be unique and should never be reused after removal
- node `name` and `host` must not contain whitespace
- every node must declare `ssh_user` and `ssh_key`
- relay ports derived from `relay_port_base + id` must stay in range and not collide with peers' `direct_port`

## Quick start

1. Copy one of the example inventories to `configs/inventory.json`.
2. Fill in:
   - real node hosts
   - per-node SSH credentials
   - `subs.domain`, `subs.caddy_host`, `subs.sub_secret`, `subs.origin_verify_secret`
   - pre-existing `xray.reality.private_key` and `xray.reality.public_key`
   - one shared `hysteria_stats_secret` value on every Hysteria-enabled node
   - `xray.users`

Deployment never generates, rotates, or changes inventory secrets. Missing or divergent secret fields cause validation to fail without printing their values.

## Hysteria2 (optional)

Hysteria2 ([apernet/hysteria](https://github.com/apernet/hysteria)) is a separate UDP/QUIC server, not an Xray protocol. The Xray component controller runs it next to `xray`, `warp`, and `adguard-home` through a Compose profile. It is enabled per node.

To enable it on a node:

1. Set `hysteria.acme_email` in `inventory.json` (shared across every node that opts in - only needs setting once).
2. On that node, point a real DNS A/AAAA record at its `host`/IP, set that name as the node's `tls_domain`, and add `"hysteria"` to the node's `protocols` array (e.g. `"protocols": ["xray", "hysteria"]`). The domain is required because Hysteria2 uses a real ACME (Let's Encrypt) certificate for TLS, and public CAs cannot issue a certificate for a bare IP address - unlike Reality, which borrows a foreign site's handshake and needs no domain of its own.
3. Deploy that node with `./mesh.sh deploy xray --node NAME`. It opens port 80 for the ACME HTTP-01 challenge and binds the node's `direct_port` on UDP for Hysteria2. Other nodes are unaffected.
4. Regenerate subscriptions - each user gets an additional `hysteria2://` link for that node, using the same UUID as their VLESS credential.

Notes:

- Hysteria2 is direct-connect only: it does not go through the HAProxy relay mesh (`relay/`), which is TCP passthrough only by design. There's no "via entry node" Hysteria2 link.
- `masquerade_url` (what a non-authenticated/probing connection is proxied to) defaults to `https://<xray.reality.sni>` if left empty.
- The ACME cert cache lives under each node's `hysteria/acme/` on the remote host and is never touched by redeploys (same treatment as `adguard/work`), so re-deploying doesn't re-issue certificates.

## Using `mesh.sh`

`mesh.sh` is the operator entrypoint. Component controllers remain explicit internal implementation details.

Open the interactive UI:

```bash
./mesh.sh
```

The menu exposes the operational flow:

- deploy Xray to one node or all nodes
- deploy relay mesh config to one node or all nodes
- generate subscriptions locally
- sync subscriptions to the Caddy host
- deploy or update Caddy
- roll back relay config on one node
- remove a node from inventory
- set up or destroy the CDN certificate stack

The normalized non-interactive interface is:

```bash
./mesh.sh check
./mesh.sh render <xray|relay> --node NAME --output DIR
./mesh.sh plan <component|all> [--node NAME]
./mesh.sh deploy <component|all> [--node NAME]
./mesh.sh status [--node NAME]
./mesh.sh rollback <xray|relay> --node NAME
./mesh.sh bootstrap --node NAME
./mesh.sh node prune --node NAME
./mesh.sh node remove --node NAME
./mesh.sh cdn plan
./mesh.sh cdn apply
./mesh.sh cdn destroy
```

Global options are `--inventory PATH`, `--dry-run`, `--yes`, `--non-interactive`, `--timeout SECONDS`, and `--verbose`. Render also accepts `--output DIR`. Legacy command aliases are not retained.

To use a different inventory file with the normalized CLI:

```bash
./mesh.sh --inventory ./configs/examples/inventory.2node.json plan all
```


## Node lifecycle

To remove the deployed Xray and HAProxy applications, containers, deployment files, logs, and Xray system hooks from a server while keeping its inventory entry:

```bash
./mesh.sh node prune --node NAME
```

The command requires typing the node name to confirm. Preview the operation without changing the server:

```bash
./mesh.sh node prune --node NAME --dry-run
```

Pruning does not remove Docker, system packages, BBR configuration, or the node from `configs/inventory.json`. The node can be deployed again later with normalized deploy commands.

To remove a node from the mesh bookkeeping:

```bash
./mesh.sh node remove --node NAME
./mesh.sh deploy relay
./mesh.sh deploy subscriptions
```

Node removal updates only the inventory. It does not shut down the old server.

To roll back Xray or HAProxy on one node:

```bash
./mesh.sh rollback xray --node NAME
./mesh.sh rollback relay --node NAME
```

## Notes

- The scripts are designed as push-model deploys from the local machine.
- Logging goes to stderr in shared helpers so command substitution remains safe.
 
## Example 3-node network

Simple view of a 3-server setup:

How to read it:

- `CloudFront / Caddy`: gives the client its subscription file
- `direct`: client connects straight to that node's `direct_port`
- `relay`: client connects to an entry node host on the relay port assigned to the target peer node

For `inventory.3node.json`:

- `server1` is the input node because it has `is_relay_entry: true`
- `server2` and `server3` are regular mesh nodes
- users get direct links to all visible nodes
- users also get relay links `via server1` for every peer of `server1`
- more generally, every relay entry node can communicate with all other nodes through its per-peer relay listeners

Mermaid version for GitHub rendering:

```mermaid
flowchart TD
    A[Client app] --> B[Subscription URL]
    B --> C[CloudFront CDN]
    C --> D[Caddy on subscription host]
    D --> E[Generated subscriptions]

    E --> F[Direct link: server1]
    E --> G[Direct link: server2]
    E --> H[Direct link: server3]
    E --> I[Relay links via server1]

    F --> K[server1]
    G --> L[server2]
    H --> M[server3]
    I --> N[  to server2]
    I --> O[  to server3]

    subgraph Mesh relay listeners
        P[server1]
        Q[server2]
        R[server3]
    end

    P -->|8444| Q
    P -->|8445| R
    Q -->|8443| P
    Q -->|8445| R
    R -->|8443| P
    R -->|8444| Q
```
