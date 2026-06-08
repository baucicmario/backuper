#!/usr/bin/env bash
# tasks/05-consolidate.sh
# Move all Immich-related folders from split_stacks and the DB backup directory
# into a single consolidated 'immich/' subtree inside split_stacks.
#
# Before:
#   split_stacks/
#     immich__immich-server/
#     immich__database/
#     immich__redis/
#     ...
#   immich_backups/
#     20260608T123456Z/
#       immich_db.sql.gz
#       library/
#
# After:
#   split_stacks/
#     immich/
#       immich-server/        ← was immich__immich-server/
#       database/             ← was immich__database/
#       redis/                ← was immich__redis/
#       20260608T123456Z/     ← was immich_backups/20260608T123456Z/
#
# Inputs (env):
#   STATE_FILE           — accumulated state (for RUN_ID; optional)
#   CENTRAL_BACKUP_DIR   — root backup dir (from lib/common.sh)
#   IMMICH_STACK_PREFIX  — folder prefix to match in split_stacks (default: immich)
#   IMMICH_OUT_NAME      — destination subfolder name (default: immich)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../../lib/common.sh"

# ── Source state (optional — only needed for context logging) ─────────────────
if [[ -n "${STATE_FILE:-}" && -f "${STATE_FILE:-}" ]]; then
  # shellcheck source=/dev/null
  source "$STATE_FILE"
fi

IMMICH_STACK_PREFIX="${IMMICH_STACK_PREFIX:-immich}"
IMMICH_OUT_NAME="${IMMICH_OUT_NAME:-immich}"

SRC_SPLIT_DIR="$CENTRAL_BACKUP_DIR/split_stacks"
SRC_DB_DIR="$CENTRAL_BACKUP_DIR/immich_backups"
DST_DIR="$SRC_SPLIT_DIR/$IMMICH_OUT_NAME"

bold "🗂  Immich Consolidation"
line
info "  Source split_stacks  : $SRC_SPLIT_DIR"
info "  Source DB backups    : $SRC_DB_DIR"
info "  Destination          : $DST_DIR"
line

[[ -d "$SRC_SPLIT_DIR" ]] || die "split_stacks directory not found: $SRC_SPLIT_DIR — run phase-1 first"

# ── Collect immich__ service folders ─────────────────────────────────────────
mapfile -t IMMICH_DIRS < <(
  find "$SRC_SPLIT_DIR" -mindepth 1 -maxdepth 1 -type d \
    -name "${IMMICH_STACK_PREFIX}__*" | sort
)

[[ ${#IMMICH_DIRS[@]} -gt 0 ]] || die \
  "No '${IMMICH_STACK_PREFIX}__*' folders found in $SRC_SPLIT_DIR. " \
  "Run phase-1 first, or check IMMICH_STACK_PREFIX."

if [[ -d "$DST_DIR" ]]; then
  die "Destination already exists: $DST_DIR — remove it or pass --skip-consolidate if consolidation already ran"
fi

mkdir -p "$DST_DIR"

# ── Move service folders ──────────────────────────────────────────────────────
info "Moving service folders into $IMMICH_OUT_NAME/..."
for src_dir in "${IMMICH_DIRS[@]}"; do
  folder_name="$(basename "$src_dir")"
  service_name="${folder_name#${IMMICH_STACK_PREFIX}__}"
  dst_service_dir="$DST_DIR/$service_name"
  info "  $folder_name  →  $IMMICH_OUT_NAME/$service_name"
  mv "$src_dir" "$dst_service_dir"
  ok "  Moved: $service_name"
done

# ── Move DB backup runs ───────────────────────────────────────────────────────
if [[ -d "$SRC_DB_DIR" ]]; then
  mapfile -t DB_DIRS < <(find "$SRC_DB_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

  if [[ ${#DB_DIRS[@]} -eq 0 ]]; then
    warn "No DB backup run folders found in $SRC_DB_DIR — skipping"
  else
    info "Moving DB backup runs..."
    for db_dir in "${DB_DIRS[@]}"; do
      folder_name="$(basename "$db_dir")"
      dst_db="$DST_DIR/$folder_name"
      info "  $folder_name  →  $IMMICH_OUT_NAME/$folder_name"
      mv "$db_dir" "$dst_db"
      ok "  Moved: $folder_name"
    done
  fi

  # Remove the now-empty immich_backups dir
  if [[ -z "$(ls -A "$SRC_DB_DIR" 2>/dev/null)" ]]; then
    rmdir "$SRC_DB_DIR"
    info "Removed empty directory: $SRC_DB_DIR"
  fi
else
  warn "No immich_backups directory found at $SRC_DB_DIR — skipping DB move"
fi

# ── Final output layout ───────────────────────────────────────────────────────
echo
line
bold "✅ Consolidation complete."
info "  Layout under: $DST_DIR"
find "$DST_DIR" -mindepth 1 -maxdepth 1 | sort | while IFS= read -r item; do
  echo "    $(basename "$item")/"
done
line
