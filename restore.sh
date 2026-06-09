#!/usr/bin/env bash
# restore.sh — Public entrypoint: headless restore of Dockge service backups.
# Usage: ./restore.sh <path>           (archive, bundle, or directory)
#        ./restore.sh <path> [--work-dir /tmp/restore] [--select-all]
#        ./restore.sh <path> [--archives name1.tar.gz name2.tar.gz]
#        ./restore.sh <path> [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

exec "$SCRIPT_DIR/modules/restore/run.sh" "$@"
