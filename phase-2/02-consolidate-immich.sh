#!/usr/bin/env bash
# phase-2/02-consolidate-immich.sh
# Moves all immich__* split stack folders into a single immich/ parent folder,
# stripping the "immich__" prefix, and places the DB dump alongside them.
#
# Env overrides:
#   CENTRAL_BACKUP_DIR   — backup root (from lib/common.sh)
#   IMMICH_STACK_PREFIX  — split folder prefix to match (default: immich)
#   IMMICH_OUT_NAME      — output folder name inside split_stacks (default: immich)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# ── Config ────────────────────────────────
IMMICH_STACK_PREFIX="${IMMICH_STACK_PREFIX:-immich}"
IMMICH_OUT_NAME="${IMMICH_OUT_NAME:-immich}"

SRC_SPLIT_DIR="$CENTRAL_BACKUP_DIR/split_stacks"
SRC_DB_DIR="$CENTRAL_BACKUP_DIR/immich_backups"
DST_DIR="$SRC_SPLIT_DIR/$IMMICH_OUT_NAME"

bold "📦 Immich Stack Consolidator"
line
info "  Source split_stacks : $SRC_SPLIT_DIR"
info "  Source DB backups   : $SRC_DB_DIR"
info "  Destination         : $DST_DIR"
line

# ── Pre-flight ────────────────────────────
[[ -d "$SRC_SPLIT_DIR" ]] || die "split_stacks not found: $SRC_SPLIT_DIR"

mapfile -t IMMICH_DIRS < <(
  find "$SRC_SPLIT_DIR" -mindepth 1 -maxdepth 1 -type d \
    -name "${IMMICH_STACK_PREFIX}__*" | sort
)

[[ ${#IMMICH_DIRS[@]} -gt 0 ]] \
  || die "No '${IMMICH_STACK_PREFIX}__*' folders found in $SRC_SPLIT_DIR"

[[ -d "$DST_DIR" ]] \
  && die "Destination already exists: $DST_DIR — remove it first or check if consolidation already ran"

mkdir -p "$DST_DIR"

# ── 1. Move each immich__<service> folder → immich/<service> ─────────────────
info "Moving service folders..."

for src_dir in "${IMMICH_DIRS[@]}"; do
  folder_name="$(basename "$src_dir")"
  # Strip the "immich__" prefix to get just the service name
  service_name="${folder_name#"${IMMICH_STACK_PREFIX}__"}"
  dst_service_dir="$DST_DIR/$service_name"

  info "  Moving: $folder_name → immich/$service_name"
  mv "$src_dir" "$dst_service_dir"
  ok "  Moved $service_name"
done

# ── 2. Move DB dump folders into the consolidated dir ────────────────────────
if [[ -d "$SRC_DB_DIR" ]]; then
  mapfile -t DB_DIRS < <(find "$SRC_DB_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

  if [[ ${#DB_DIRS[@]} -eq 0 ]]; then
    warn "No DB backup folders found in $SRC_DB_DIR — skipping"
  else
    for db_dir in "${DB_DIRS[@]}"; do
      folder_name="$(basename "$db_dir")"
      dst_db="$DST_DIR/$folder_name"
      info "Moving DB backup: $db_dir → $dst_db"
      mv "$db_dir" "$dst_db"
      ok "Moved $folder_name"
    done
  fi

  # Clean up empty source dir
  if [[ -z "$(ls -A "$SRC_DB_DIR")" ]]; then
    rmdir "$SRC_DB_DIR"
    info "Removed empty dir: $SRC_DB_DIR"
  fi
else
  warn "No immich_backups dir found at $SRC_DB_DIR — skipping DB dump move"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
line
bold "✅ Done. Immich consolidated at: $DST_DIR"
line