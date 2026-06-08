#!/usr/bin/env bash
# phase2.sh — Entry point for Phase 2 (Immich-Specific Backup & Consolidation)
# This script detects Immich installations, backs up the database and library,
# and consolidates all backups into a unified Immich stack folder.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/run_phase.sh"

# Set backup root directory for Immich backups
export BACKUP_ROOT="${CENTRAL_BACKUP_DIR}/immich_backups"

# Run all scripts in phase-2 directory
run_phase "$SCRIPT_DIR/phase-2" "Phase 2" "$@"