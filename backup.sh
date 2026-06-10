#!/usr/bin/env bash
# backup.sh — Public entrypoint: backup all Dockge-managed Docker Compose stacks.
# Usage: ./backup.sh [--dry-run] [--force] [--copy-all] [--reject-all]
#        ./backup.sh [--stacks-dir /opt/stacks] [--output /mnt/backup]
#        ./backup.sh [--archive]            # pack each service dir into .tar.gz
#        ./backup.sh [--archive-replace]    # pack and remove source dirs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

exec bash "$SCRIPT_DIR/modules/backup/run.sh" "$@"
