# Getting started

## Requirements

Local tools used by the deployment framework:

- `bash`
- `jq`
- `ssh`
- `scp`
- `curl`
- `sha256sum`
- `base64`
- AWS CLI for explicit CDN apply and destroy operations
- `qrencode` optionally, for QR output during subscription generation

Each remote node requires SSH access with the inventory's `ssh_user` and
`ssh_key`, plus `sudo`. Bootstrap installs Docker, Docker Compose, `zstd`, cron,
and the required host configuration:

```bash
./mesh.sh bootstrap --node NAME
```

## Configure the inventory

The default inventory is `configs/inventory.json`. Start with a committed
example:

```bash
cp configs/examples/inventory.2node.json configs/inventory.json
```

Set at least:

- real node hosts and per-node SSH credentials
- `subs.domain`, `subs.caddy_host`, `subs.sub_secret`, and
  `subs.origin_verify_secret`
- an existing `xray.reality.private_key` and `xray.reality.public_key`
- `xray.users`
- one shared `hysteria_stats_secret` on every Hysteria-enabled node

Deployment never generates, rotates, or changes inventory secrets. Validation
rejects missing or divergent secrets without printing their values.

The primary inventory sections are:

- `relay_port_base` - base used to derive peer relay listeners
- `resolvers` - HAProxy DNS resolver settings
- `subs` - subscription and Caddy configuration
- `xray.reality` - shared Reality keys, SNI, and short ID
- `xray.dns` - server-side Xray and Hysteria DNS settings
- `xray.users` - users, UUIDs, and optional hidden nodes
- `hysteria` - shared Hysteria2 settings
- `nodes` - node identity, host, port, SSH, protocol, and relay-entry settings

See [the example inventory reference](../configs/examples/README.md) for every
field and enforced invariant.

## Validate and inspect

Validate the local configuration:

```bash
./mesh.sh check
```

Inspect required firewall ports and DNS records without contacting hosts or
AWS:

```bash
./mesh.sh network
```

Preview rendered and remote changes before deployment:

```bash
./mesh.sh plan all
./mesh.sh plan xray --node NAME
```

## First deployment

The interactive interface exposes the complete workflow:

```bash
./mesh.sh
```

The equivalent explicit sequence is:

```bash
./mesh.sh deploy xray
./mesh.sh deploy relay
./mesh.sh deploy stats
./mesh.sh deploy web
./mesh.sh deploy caddy
./mesh.sh deploy subscriptions
```

Use `./mesh.sh deploy all` when the full configured stack should be deployed in
dependency order. CDN provisioning remains separate because it creates
billable AWS resources and modifies firewall policy:

```bash
./mesh.sh cdn plan
./mesh.sh cdn apply
```

## Enable Hysteria2 on a node

Hysteria2 is a separate UDP/QUIC server managed by the Xray component. It is
enabled per node.

1. Set the shared `hysteria.acme_email`.
2. Point a real DNS A/AAAA record at the node.
3. Set the node's `tls_domain` to that DNS name.
4. Add `hysteria` to the node's protocols, for example
   `"protocols": ["xray", "hysteria"]`.
5. Set the same `hysteria_stats_secret` on every Hysteria-enabled node.
6. Deploy Xray on the node and regenerate subscriptions.

```bash
./mesh.sh deploy xray --node NAME
./mesh.sh deploy subscriptions
```

Hysteria2 binds the node's `direct_port` over UDP while Xray uses the same port
over TCP. TCP port 80 is used for Hysteria2's ACME HTTP-01 challenge. Hysteria2
is direct-connect only and does not use the HAProxy relay mesh.

The certificate cache under `hysteria/acme/` and AdGuard runtime data are
persistent and are not replaced during normal deployment.
