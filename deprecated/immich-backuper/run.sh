#!/usr/bin/env bash
# phase-2/orchestrator.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../../lib/common.sh"

S="$SCRIPT_DIR/steps"

STATE_FILE="$(mktemp /tmp/immich_state.XXXX.env)"
export BACKUP_ROOT RUN_ID STATE_FILE
trap 'rm -f "$STATE_FILE"' EXIT

# STEP 1 — Detect Immich deployment
bash "$S/01-detect-immich.sh"

# STEP 2 — Backup PostgreSQL database
bash "$S/02-backup-database.sh"

# STEP 3 — Generate backup manifest
bash "$S/03-write-manifest.sh"

# STEP 4 — Consolidate Immich backup
bash "$S/04-consolidate.sh"

# STEP 5 — Generate master restore script
bash "$S/05-write-restore.sh"

ok "🎉 Phase 2 complete."