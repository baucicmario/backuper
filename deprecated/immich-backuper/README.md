# DEPRECATED: Immich Backuper

> **Do not use this module for new deployments.**

This module was superseded by the generic backup pipeline in `modules/backup/`.
Immich services (immich-server, immich-microservices, postgres, redis) are
fully handled by `backup.sh` as of the Option B restructure — no special-casing
needed.

The root-level `phase2.sh` has been replaced with an exit-with-notice stub.
Use `./backup.sh` instead.

This directory is preserved for historical reference only and will be removed
in a future major version.

## What it did

1. Auto-detected the Immich compose stack under `/opt/stacks`
2. Dumped the PostgreSQL database via `pg_dumpall`
3. Wrote a manifest of backed-up files
4. Consolidated everything into a single output folder
5. Generated a restore script

All of this is now handled generically by `modules/backup/` for every
Docker Compose service, including Immich.
