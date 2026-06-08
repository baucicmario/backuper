#!/usr/bin/env bash
# phase-2/orchestrator.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

T="$SCRIPT_DIR/tasks"

BACKUP_ROOT="${BACKUP_ROOT:-$CENTRAL_BACKUP_DIR/immich_backups}"
export BACKUP_ROOT

# Create a proper mktemp state file — not a hardcoded /tmp path
STATE_FILE="$(mktemp /tmp/immich_state.XXXX.env)"
export STATE_FILE
trap 'rm -f "$STATE_FILE"' EXIT

# STEP 1 — Detect Immich
bash "$T/00-detect-immich.sh"

# STEP 2 — Backup database + library
bash "$T/01-backup-immich.sh"

# STEP 3 — Consolidate into split_stacks
bash "$T/02-consolidate-immich.sh"

ok "🎉 Phase 2 complete."