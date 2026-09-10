# Deployment operations

## Operator interface

Run `./mesh.sh` without arguments to open the interactive interface. The
normalized non-interactive commands are:

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
./mesh.sh network
./mesh.sh adguard ui --node NAME
```

Components accepted by `plan` and `deploy` are `xray`, `relay`, `stats`, `web`,
`caddy`, and `subscriptions`. Global options are `--inventory PATH`,
`--dry-run`, `--yes`, `--non-interactive`, `--timeout SECONDS`, and `--verbose`.
The `render` command also accepts `--output DIR`.

Place global options before the command:

```bash
./mesh.sh --inventory configs/examples/inventory.2node.json plan all
```

## Command classification

| Command | Scope | Classification | Notes |
| --- | --- | --- | --- |
| `./mesh.sh check` | Local | Read-only | Syntax, static analysis, compilation, rendering, and unit tests. |
| `./mesh.sh render ...` | Local | Read-only | Writes only to an explicitly selected local output directory. |
| `./mesh.sh plan ...` | Local and remote | Read-only | Renders locally and compares remote managed manifests. |
| `./mesh.sh status` | Remote | Read-only | Reads Compose and container health state. |
| `./mesh.sh deploy ...` | Remote | State-changing | Stages, validates, promotes, applies, verifies, and rolls back on failure. |
| `./mesh.sh rollback ...` | Remote | State-changing | Restores a prior managed configuration. |
| `./mesh.sh bootstrap ...` | Remote | State-changing | Installs host packages and configures host prerequisites. |
| `./mesh.sh node prune ...` | Remote | Destructive | Deletes managed services and files, preserving inventory. |
| `./mesh.sh node remove ...` | Local | Destructive | Removes a node from inventory; does not modify its host. |
| `./mesh.sh cdn plan` | Local | Read-only | Describes planned ACM, CloudFront, Route53, and firewall changes. |
| `./mesh.sh cdn apply` | AWS and remote | State-changing, billable | Creates or updates AWS resources and firewall rules. |
| `./mesh.sh cdn destroy` | AWS and remote | Destructive | Deletes AWS resources and reverses managed firewall changes. |
| `./mesh.sh network` | Local | Read-only | Derives required inbound ports and Route53 records from the current inventory. |
| `./mesh.sh adguard ui --node NAME` | Remote tunnel | Read-only | Opens a local SSH tunnel to the selected node's AdGuard Home UI and launches the browser. |

There are no legacy command aliases. The certificate scripts are state-changing and must not be used as plan operations.

## Deployment dependency graph

`deploy all` is intentionally serial:

1. Validate the full inventory and preflight every selected target.
2. Deploy Xray and optional Hysteria node services.
3. Deploy relay routing after node listeners are healthy.
4. Deploy the central stats backend after node APIs are healthy.
5. Deploy the optional web service after stats is healthy.
6. Deploy optional Caddy before subscription sync.
7. Generate subscriptions locally.
8. Sync subscriptions after Caddy is healthy.

CDN provisioning is excluded because it creates billable AWS resources and changes firewall policy.

## Network and DNS report

```bash
./mesh.sh network
```

This local, read-only command derives the following requirements from the
current inventory:

- inbound Xray TCP ports
- Hysteria2 UDP ports and TCP port 80 where Hysteria2 is enabled
- HAProxy relay ports on nodes marked `is_relay_entry: true`
- stats, web, and Caddy ports where configured
- Route53 records for Hysteria TLS domains, Caddy, and the stats web service

It does not contact remote hosts or AWS. The subscription domain is reported as
requiring a CloudFront CNAME or alias; use `./mesh.sh cdn plan` to inspect that
infrastructure.

Open a node's AdGuard Home interface through a local SSH tunnel:

```bash
./mesh.sh adguard ui --node NAME
```

The command forwards remote `127.0.0.1:3000` to local `127.0.0.1:3000` and
closes the tunnel with Ctrl-C. Set `ADGUARD_LOCAL_PORT` when the local port is
already occupied.

## Node lifecycle

Remove deployed Xray and HAProxy services, managed files, logs, and Xray system
hooks while retaining the inventory entry:

```bash
./mesh.sh node prune --node NAME
```

The command requires the node name as confirmation. Preview it without changing
the host:

```bash
./mesh.sh node prune --node NAME --dry-run
```

Pruning does not remove Docker, system packages, BBR configuration, or the node
from inventory.

Remove a node from mesh bookkeeping, then reconcile dependent configuration:

```bash
./mesh.sh node remove --node NAME
./mesh.sh deploy relay
./mesh.sh deploy subscriptions
```

Node removal changes only the local inventory. It does not stop or modify the
removed host.

Restore the latest managed backup for Xray or HAProxy on one node:

```bash
./mesh.sh rollback xray --node NAME
./mesh.sh rollback relay --node NAME
```

## Safety boundaries

- Deployment targets are under `/opt/<component>`.
- Managed configuration and persistent data must use separate explicit manifests.
- PostgreSQL data, ACME state, AdGuard runtime state, and other persistent directories are excluded from promotion and rollback.
- Logs are disposable and may be removed.
- Multi-node deployment remains serial until remote locking and per-target result reporting are proven.
