#!/usr/bin/env bash
# modules/restore/steps/05-run-restore.sh
# Locate and execute the restore.sh script within an extracted archive directory.
#
# Mirrors the WebUI logic: searches for restore.sh at the top level first,
# then one level deep (tasks.py:122-129).
#
# All output from restore.sh is streamed directly to the terminal.
#
# Usage: 05-run-restore.sh <extracted_dir>
# Exit code: 0 on success, 1 on failure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../../lib/common.sh"

EXTRACTED_DIR="${1:?Usage: 05-run-restore.sh <extracted_dir>}"

[[ -d "$EXTRACTED_DIR" ]] || die "Extracted directory not found: $EXTRACTED_DIR"

# ── Locate restore.sh ─────────────────────────────────────────────────────────
RESTORE_SCRIPT=""

# Priority 1: Top level
if [[ -f "$EXTRACTED_DIR/restore.sh" ]]; then
  RESTORE_SCRIPT="$EXTRACTED_DIR/restore.sh"
else
  # Priority 2: One level deep (common when tar extracts into a subdirectory)
  while IFS= read -r candidate; do
    RESTORE_SCRIPT="$candidate"
    break  # Take the first match
  done < <(find "$EXTRACTED_DIR" -mindepth 1 -maxdepth 2 -name "restore.sh" -type f 2>/dev/null)
fi

if [[ -z "$RESTORE_SCRIPT" ]]; then
  warn "  No restore.sh found in $EXTRACTED_DIR"
  warn "  Contents:"
  ls -la "$EXTRACTED_DIR" >&2 2>/dev/null || true
  exit 1
fi

RESTORE_CWD="$(dirname "$RESTORE_SCRIPT")"

info "  Running: $RESTORE_SCRIPT"
info "  CWD:     $RESTORE_CWD"
line

# ── Execute restore.sh ────────────────────────────────────────────────────────
# Make it executable (it should already be, but belt and suspenders)
chmod +x "$RESTORE_SCRIPT"

# Stream all output (stdout + stderr) directly to the terminal
# Use bash explicitly to avoid issues with missing shebang execution permissions
if bash "$RESTORE_SCRIPT" 2>&1; then
  line
  return_code=0
else
  return_code=$?
  line
  error "  restore.sh exited with code $return_code"
fi

exit $return_code
