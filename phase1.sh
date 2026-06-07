#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/run_phase.sh"
# Forward CENTRAL_BACKUP_DIR to phase-1 scripts via their --output flag
run_phase "$SCRIPT_DIR/phase-1" "Phase 1" "$@" -- --output "$CENTRAL_BACKUP_DIR/split_stacks"