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

TAR_ARGS=("-C" "$PARENT_DIR" "$FOLDER_NAME")
TOTAL_SIZE_BYTES=$(du -sb "$SERVICE_DIR" 2>/dev/null | cut -f1 || echo "0")

MOUNT_LIST="$SERVICE_DIR/.backup-mounts"
if [[ -f "$MOUNT_LIST" ]]; then
  while IFS='|' read -r host_path dest_name; do
    [[ -z "$host_path" ]] && continue
    if [[ -d "$host_path" || -f "$host_path" ]]; then
      # Strip leading slash for GNU tar regex
      sed_path="${host_path#/}"
      # Use | as sed delimiter because paths contain /
      TAR_ARGS+=( "--transform=s|^${sed_path}|${FOLDER_NAME}/${dest_name}|" "$host_path" )
      
      mount_size=$(du -sb "$host_path" 2>/dev/null | cut -f1 || echo "0")
      TOTAL_SIZE_BYTES=$(( TOTAL_SIZE_BYTES + mount_size ))
    fi
  done < "$MOUNT_LIST"
fi

# Prevent .backup-mounts from being archived
[[ -f "$MOUNT_LIST" ]] && rm -f "$MOUNT_LIST"

stderr_file="$(mktemp)"

if command -v pv >/dev/null 2>&1 && [[ "$TOTAL_SIZE_BYTES" -gt 0 ]]; then
  total_size_mb=$(( TOTAL_SIZE_BYTES / 1024 / 1024 ))
  echo "[job-sub_total: $total_size_mb]"
  
  if ( ( tar cf - "${TAR_ARGS[@]}" 2>"$stderr_file" || { res=$?; [[ $res -eq 1 ]] && exit 0 || exit $res; } ) | pv -n -f -s "$TOTAL_SIZE_BYTES" | gzip > "$ARCHIVE_PATH" ) 2>&1 | awk '{ if ($1 ~ /^[0-9]+$/) { print "[pv: "$1"]"; fflush() } else { print $0 > "/dev/stderr"; fflush() } }'; then
    ARCHIVE_SIZE="$(du -h "$ARCHIVE_PATH" | awk '{print $1}')"
    ok "  Archived:  $ARCHIVE_PATH  ($ARCHIVE_SIZE)"
  else
    cat "$stderr_file" >&2
    rm -f "$stderr_file"
    die "tar failed for $SERVICE_DIR"
  fi
else
  total_size_mb=$(( TOTAL_SIZE_BYTES / 1024 / 1024 ))
  echo "[job-sub_total: $total_size_mb]"
  
  if ( tar -czf "$ARCHIVE_PATH" "${TAR_ARGS[@]}" 2>"$stderr_file" || { res=$?; [[ $res -eq 1 ]] && exit 0 || exit $res; } ); then
    ARCHIVE_SIZE="$(du -h "$ARCHIVE_PATH" | awk '{print $1}')"
    ok "  Archived:  $ARCHIVE_PATH  ($ARCHIVE_SIZE)"
  else
    cat "$stderr_file" >&2
    rm -f "$stderr_file"
    die "tar failed for $SERVICE_DIR"
  fi
fi

rm -f "$stderr_file"

# ── Remove source if requested ────────────────────────────────────────────────
if [[ "$ARCHIVE_MODE" == replace ]]; then
  rm -rf "$SERVICE_DIR"
  info "  Removed source folder: $SERVICE_DIR"
fi