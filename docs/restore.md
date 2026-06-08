# Restore Guide

Each backup package produced by `backup.sh` is fully self-contained.
Restoring a service requires no knowledge of the original system layout.

## Restore a single service

```bash
cd backups/split_stacks/players__jellyfin
sudo ./restore.sh
```

## Override the stacks directory

If restoring to a different machine where Dockge stacks live elsewhere:

```bash
DOCKGE_STACKS_DIR=/mnt/new-server/stacks sudo ./restore.sh
```

## Restore a full multi-service stack

Run each service's `restore.sh` independently. All scripts target the
same `compose.yaml` and each one merges its piece. Order does not matter.

```bash
sudo ./qbittorrentvpn__radarr/restore.sh
sudo ./qbittorrentvpn__sonarr/restore.sh
sudo ./qbittorrentvpn__bazarr/restore.sh

cd /opt/stacks/qbittorrentvpn && docker compose up -d
```

## What restore.sh does

1. Creates `$DOCKGE_STACKS_DIR/<stack>/` if it does not exist
2. Creates a bare `compose.yaml` if the file does not exist
3. Merges the service block into `compose.yaml` (skips if already present)
4. Merges network definitions (skips existing)
5. Merges volume definitions (skips existing)
6. Merges `.env` variables (appends missing keys, skips existing)
7. Restores bind-mount data back to original host paths

All merge operations are append-only and duplicate-safe.

---

For full details see [docs/backup.md](backup.md).
