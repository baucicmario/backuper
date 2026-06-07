#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/run_phase.sh"
run_phase "$SCRIPT_DIR/phase-0" "Phase 0" "$@"