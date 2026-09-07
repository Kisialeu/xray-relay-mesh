# Repository boundaries

## `bashbuild/`

The deployment framework. It owns CLI parsing, inventory access, SSH transport, staging, locking, managed-file transactions, Compose reconciliation, and explicit component controllers. It must not contain application source, Docker build contexts, or environment-specific secrets.

## `services/`

Runtime payloads deployed by the framework:

- `xray/` - Compose template, entrypoint, stats sidecar, and logrotate configuration
- `relay/` - HAProxy Compose template
- `stats/` - Python service, tests, requirements, Dockerfile, and Compose template
- `web/` - application, Nginx, Certbot, Dockerfiles, and Compose template
- `caddy/` - Caddy configuration and Compose template

Service directories must not implement SSH, inventory mutation, host bootstrap, or deployment orchestration.

## `infrastructure/`

Explicit infrastructure lifecycle operations:

- `host/` - bootstrap, prune, reset, and inventory decommission commands
- `cdn/` - ACM, CloudFront, Route53, and origin firewall lifecycle

These commands are state-changing and remain separate from routine service deployment.

## `configs/`

- `inventory.json` - ignored operator inventory
- `examples/` - committed non-production examples
- `secrets/` - ignored local secret inputs

Configuration files are data, never sourced as shell code.

## `var/`

Ignored generated artifacts such as rendered subscription content. No framework or service source belongs here.
