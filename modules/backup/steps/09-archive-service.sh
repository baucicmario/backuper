#!/usr/bin/env bash
# modules/backup/steps/09-archive-service.sh
# Pack a completed service backup directory into a portable .tar.gz archive.
#
# Called once per service directory AFTER all previous steps have finished
# writing content into it (compose, env, metadata, bind-mounts, restore.sh).
#
# Inputs (positional):
#   $1  SERVICE_DIR   — absolute path to the completed service folder
#                       e.g. /backups/split_stacks/players__jellyfin
#   $2  ARCHIVE_MODE  — controls whether the source folder is kept or removed
#                       keep   (default) — archive sits beside the folder
#                       replace          — source folder is removed after archive
#
# Outputs:
#   <SERVICE_DIR>.tar.gz   — self-contained archive of the service package
#
# The archive is created with a single top-level directory whose name matches
# the service folder, so it unpacks cleanly:
#
#   tar -xzf players__jellyfin.tar.gz
#   → players__jellyfin/
#       docker-compose.yml
#       .env
#       .stack-meta
#       restore.sh
#       config/
#
# Exit codes:
#   0  success
#   1  tar failed or SERVICE_DIR does not exist
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../../lib/common.sh"

require_cmd tar

# ── Arguments ─────────────────────────────────────────────────────────────────
SERVICE_DIR="${1:?Usage: 09-archive-service.sh <service_dir> [keep|replace]}"
ARCHIVE_MODE="${2:-keep}"

[[ -d "$SERVICE_DIR" ]] || die "Service directory not found: $SERVICE_DIR"

PARENT_DIR="$(dirname "$SERVICE_DIR")"
FOLDER_NAME="$(basename "$SERVICE_DIR")"
ARCHIVE_PATH="$PARENT_DIR/${FOLDER_NAME}.tar.gz"

# ── Dry-run guard ─────────────────────────────────────────────────────────────
# Honour the DRY_RUN flag that the orchestrator exports.
if [[ "${DRY_RUN:-false}" == true ]]; then
  info "  [dry-run] would archive: $SERVICE_DIR → $ARCHIVE_PATH"
  [[ "$ARCHIVE_MODE" == replace ]] && info "  [dry-run] would remove:  $SERVICE_DIR"
  exit 0
fi

# ── Archive ───────────────────────────────────────────────────────────────────
info "  Archiving: $FOLDER_NAME → ${FOLDER_NAME}.tar.gz"

# -C changes into the parent so the archive root is just the folder name,
# not an absolute path. This makes extraction predictable anywhere.
tar -czf "$ARCHIVE_PATH" -C "$PARENT_DIR" "$FOLDER_NAME" \
  || die "tar failed for $SERVICE_DIR"

ARCHIVE_SIZE="$(du -h "$ARCHIVE_PATH" | awk '{print $1}')"
ok "  Archived:  $ARCHIVE_PATH  ($ARCHIVE_SIZE)"

# ── Remove source if requested ────────────────────────────────────────────────
if [[ "$ARCHIVE_MODE" == replace ]]; then
  rm -rf "$SERVICE_DIR"
  info "  Removed source folder: $SERVICE_DIR"
fi