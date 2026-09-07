# Deployment operations

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
| `./mesh.sh cdn plan` | AWS | Read-only | Describes CloudFormation and firewall changes. |
| `./mesh.sh cdn apply` | AWS and remote | State-changing, billable | Creates or updates AWS resources and firewall rules. |
| `./mesh.sh cdn destroy` | AWS and remote | Destructive | Deletes AWS resources and reverses managed firewall changes. |

Legacy commands remain compatibility aliases during migration. The current certificate scripts are state-changing and must not be used as plan operations.

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

## Safety boundaries

- Deployment targets are under `/opt/<component>`.
- Managed configuration and persistent data must use separate explicit manifests.
- PostgreSQL data, ACME state, AdGuard runtime state, and other persistent directories are excluded from promotion and rollback.
- Logs are disposable and may be removed.
- Multi-node deployment remains serial until remote locking and per-target result reporting are proven.
