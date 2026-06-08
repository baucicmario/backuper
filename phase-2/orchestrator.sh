#!/usr/bin/env bash
# phase-2/orchestrator.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

T="$SCRIPT_DIR/tasks"

STATE_FILE="$(mktemp /tmp/immich_state.XXXX.env)"
export BACKUP_ROOT RUN_ID STATE_FILE
trap 'rm -f "$STATE_FILE"' EXIT

# STEP 1 — Detect Immich deployment
bash "$T/01-detect-immich.sh"

# STEP 2 — Backup PostgreSQL database
bash "$T/02-backup-database.sh"

# STEP 3 — Generate backup manifest
bash "$T/03-write-manifest.sh"

# STEP 4 — Consolidate Immich backup
bash "$T/04-consolidate.sh"

# STEP 5 — Generate master restore script
bash "$T/05-write-restore.sh"

ok "🎉 Phase 2 complete."