#!/usr/bin/env bash
# modules/restore/steps/06-cleanup.sh
# Remove the extracted directory and the source archive for a single restore.
# Ensures no temporary files are left behind after a successful restore.
#
# Usage: 06-cleanup.sh <extracted_dir> <archive_path>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../../lib/common.sh"

EXTRACTED_DIR="${1:?Usage: 06-cleanup.sh <extracted_dir> <archive_path>}"
ARCHIVE_PATH="${2:?}"

# ── Remove extracted directory ────────────────────────────────────────────────
if [[ -d "$EXTRACTED_DIR" ]]; then
  rm -rf "$EXTRACTED_DIR"
  info "  Cleaned up: $(basename "$EXTRACTED_DIR")/"
fi

# Also clean the parent if it was a double-nested extraction
# (e.g., work_dir/name/name/ → also remove work_dir/name/)
PARENT_DIR="$(dirname "$EXTRACTED_DIR")"
PARENT_NAME="$(basename "$PARENT_DIR")"
WORK_DIR="$(dirname "$PARENT_DIR")"

# Only remove parent if it's empty and it's not the work directory itself
if [[ -d "$PARENT_DIR" && "$PARENT_DIR" != "$WORK_DIR" ]]; then
  if [[ -z "$(ls -A "$PARENT_DIR" 2>/dev/null)" ]]; then
    rm -rf "$PARENT_DIR"
    info "  Cleaned up empty parent: $PARENT_NAME/"
  fi
fi

# ── Remove source archive ────────────────────────────────────────────────────
if [[ -f "$ARCHIVE_PATH" ]]; then
  rm -f "$ARCHIVE_PATH"
  info "  Removed archive: $(basename "$ARCHIVE_PATH")"
fi
