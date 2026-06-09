#!/usr/bin/env bash
# modules/restore/steps/01-intake.sh
# Process a source path and stage its archives into the work directory.
#
# Handles three cases:
#   Case A: Archive-of-archives bundle  → extract, delete container
#   Case B: Individual .tar.gz archive  → move to work dir
#   Case C: Existing directory           → copy/symlink archives into work dir
#
# Usage: 01-intake.sh <source_path> <work_dir> [dry_run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../../lib/common.sh"

SOURCE_PATH="${1:?Usage: 01-intake.sh <source_path> <work_dir> [dry_run]}"
WORK_DIR="${2:?}"
DRY_RUN="${3:-false}"

# Resolve to absolute path
SOURCE_PATH="$(realpath "$SOURCE_PATH" 2>/dev/null || echo "$SOURCE_PATH")"

[[ -e "$SOURCE_PATH" ]] || die "Source path not found: $SOURCE_PATH"

# ── File processing logic ──────────────────────────────────────────────────────
process_file() {
  local file="$1"
  local file_name="$(basename "$file")"

  if [[ ! "$file" =~ \.tar\.gz$ && ! "$file" =~ \.tgz$ ]]; then
    warn "  Skipping non-archive file: $file_name"
    return 0
  fi

  info "  Inspecting archive: $file_name"

  # List top-level contents of the archive
  local top_level_tarballs=0
  local top_level_dirs=0

  while IFS= read -r entry; do
    # Normalize: strip trailing slash, get top-level component only
    local top="$(echo "$entry" | cut -d'/' -f1)"

    if [[ "$entry" =~ \.tar\.gz$ ]] && [[ "$entry" == "$top" || "$entry" == "$top/" ]]; then
      # This is a .tar.gz file at the top level
      (( top_level_tarballs++ )) || true
    fi
  done < <(tar -tzf "$file" 2>/dev/null | head -100)

  # Count distinct top-level entries
  local distinct_top_levels="$(tar -tzf "$file" 2>/dev/null | cut -d'/' -f1 | sort -u | wc -l)"

  # Heuristic: if the archive contains .tar.gz files at root level, it's a bundle.
  # Also: if there are multiple distinct top-level directories, it's likely a bundle.
  local is_bundle=false
  if (( top_level_tarballs >= 2 )); then
    is_bundle=true
  elif (( distinct_top_levels > 1 )); then
    # Check if those top-level entries are .tar.gz files
    local tarball_count="$(tar -tzf "$file" 2>/dev/null | grep -cE '^[^/]+\.tar\.gz$' || echo 0)"
    if (( tarball_count >= 2 )); then
      is_bundle=true
    fi
  fi

  # ── Case A: Archive-of-archives bundle ──────────────────────────────────────
  if [[ "$is_bundle" == true ]]; then
    info "  Case A: Archive-of-archives bundle detected"

    if [[ "$DRY_RUN" == true ]]; then
      info "  [dry-run] would extract bundle to work directory: $file_name"
      return 0
    fi

    # Extract the bundle into the work directory with progress
    extract_with_progress "$file" "$WORK_DIR" "$file_name"

    # Move any extracted .tar.gz files that ended up in subdirectories to the work dir root
    find "$WORK_DIR" -mindepth 2 -name "*.tar.gz" -exec mv {} "$WORK_DIR/" \; 2>/dev/null || true

    ok "  Bundle extracted into staging directory"
    return 0
  fi

  # ── Case B: Individual restore archive ──────────────────────────────────────
  info "  Case B: Individual restore archive detected"
  local dest="$WORK_DIR/$file_name"

  if [[ "$DRY_RUN" == true ]]; then
    info "  [dry-run] would stage: $file_name"
  else
    if [[ "$(dirname "$(realpath "$file")")" == "$(realpath "$WORK_DIR")" ]]; then
      info "  Archive already in work directory"
    else
      cp "$file" "$dest"
      ok "  Staged: $file_name"
    fi
  fi
}

# ── Entrypoint ────────────────────────────────────────────────────────────────
if [[ -d "$SOURCE_PATH" ]]; then
  info "  Case C: Directory detected — $SOURCE_PATH"
  
  archive_count=0
  while IFS= read -r -d '' archive; do
    process_file "$archive"
    (( archive_count++ )) || true
  done < <(find "$SOURCE_PATH" -maxdepth 1 -type f -name "*.tar.gz" -print0 | sort -z)

  if [[ $archive_count -eq 0 ]]; then
    warn "  No .tar.gz archives found in $SOURCE_PATH"
  else
    ok "  Finished staging archives from directory"
  fi
else
  if [[ ! -f "$SOURCE_PATH" ]]; then
    die "Source is neither a file nor a directory: $SOURCE_PATH"
  fi
  process_file "$SOURCE_PATH"
fi
