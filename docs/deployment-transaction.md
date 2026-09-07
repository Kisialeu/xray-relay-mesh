# Managed deployment transaction

Each component uses an explicit, serial transaction:

1. Render into a local stage created by `stage_create`.
2. Write a deterministic `.mesh-manifest` containing relative path, mode, and SHA-256 digest.
3. Run remote preflight and acquire `<deploy-dir>/.deploy.lock`.
4. Upload to `<deploy-dir>/.staging/<run-id>`.
5. Validate the staged Compose and component configuration before promotion.
6. Compare the staged manifest with the active manifest and stop on a true no-op.
7. Back up only files from the active managed manifest.
8. Remove obsolete managed files and promote only files from the new manifest.
9. Apply with `docker compose up -d --remove-orphans` and wait for container health.
10. On failure, restore the managed backup and reapply it.
11. Record the backup pointer, remove the stage, release the lock, and print a deployment summary.

## Persistent state

The following paths are never listed in managed manifests and are therefore never replaced or restored by the transaction:

- Xray logs
- AdGuard `work/` runtime data
- Hysteria and Caddy ACME state
- Caddy named volumes
- PostgreSQL data
- Web certificate state

Only a component's destructive prune/reset command may remove persistent state, after explicit confirmation.
