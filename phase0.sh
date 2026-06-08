#!/usr/bin/env bash
# phase0.sh — Entry point for Phase 0 (System Setup)
# This script initializes the system with all required dependencies and tools.
# It discovers the script directory, loads the phase runner utility, and executes
# all phase-0 scripts in order.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/run_phase.sh"

# Run all scripts in phase-0 directory
run_phase "$SCRIPT_DIR/phase-0" "Phase 0" "$@"