#!/usr/bin/env bash
# phase-2/orchestrator.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

T="$SCRIPT_DIR/tasks"

BACKUP_ROOT="${BACKUP_ROOT:-$CENTRAL_BACKUP_DIR/immich_backups}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
STATE_FILE="$(mktemp /tmp/immich_state.XXXX.env)"
export BACKUP_ROOT RUN_ID STATE_FILE
trap 'rm -f "$STATE_FILE"' EXIT

# STEP 1 — Detect Immich deployment
bash "$T/01-detect-immich.sh"

# STEP 2 — Backup PostgreSQL database
bash "$T/02-backup-database.sh"

# STEP 3 — Backup media library
bash "$T/03-backup-library.sh"

# STEP 4 — Generate backup manifest
bash "$T/04-write-manifest.sh"

# STEP 5 — Consolidate Immich backup
bash "$T/05-consolidate.sh"

ok "🎉 Phase 2 complete."