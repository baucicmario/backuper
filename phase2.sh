#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/run_phase.sh"

export BACKUP_ROOT="${CENTRAL_BACKUP_DIR}/immich_backups"
run_phase "$SCRIPT_DIR/phase-2" "Phase 2" "$@"