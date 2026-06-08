#!/usr/bin/env bash
# phase1.sh — Entry point for Phase 1 (Stack Discovery & Service Extraction)
# This script discovers all Dockge stacks, extracts individual services,
# and backs up their configurations and data.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/run_phase.sh"

# Run all scripts in phase-1 directory
# Forward CENTRAL_BACKUP_DIR to phase-1 scripts via their --output flag
run_phase "$SCRIPT_DIR/phase-1" "Phase 1" "$@" -- --output "$CENTRAL_BACKUP_DIR/split_stacks"