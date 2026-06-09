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

# ── Case C: Existing directory ────────────────────────────────────────────────
if [[ -d "$SOURCE_PATH" ]]; then
  info "  Case C: Directory detected — $SOURCE_PATH"

  # Copy (or link) .tar.gz files from the source directory into the work dir
  archive_count=0
  while IFS= read -r -d '' archive; do
    archive_name="$(basename "$archive")"
    dest="$WORK_DIR/$archive_name"

    # Skip if already present (e.g. work dir IS the source dir)
    if [[ "$(realpath "$archive")" == "$(realpath "$dest" 2>/dev/null || echo "")" ]]; then
      (( archive_count++ )) || true
      continue
    fi

    if [[ "$DRY_RUN" == true ]]; then
      info "  [dry-run] would stage: $archive_name"
    else
      cp "$archive" "$dest"
    fi
    (( archive_count++ )) || true
  done < <(find "$SOURCE_PATH" -maxdepth 1 -type f -name "*.tar.gz" -print0 | sort -z)

  if [[ $archive_count -eq 0 ]]; then
    warn "  No .tar.gz archives found in $SOURCE_PATH"
  else
    ok "  Staged $archive_count archive(s) from directory"
  fi
  exit 0
fi

# ── It's a file — determine if it's Case A (bundle) or Case B (individual) ───
if [[ ! -f "$SOURCE_PATH" ]]; then
  die "Source is neither a file nor a directory: $SOURCE_PATH"
fi

# Check if it's a tar.gz
if [[ ! "$SOURCE_PATH" =~ \.tar\.gz$ && ! "$SOURCE_PATH" =~ \.tgz$ ]]; then
  die "Source file is not a .tar.gz archive: $SOURCE_PATH"
fi

# ── Detect if this is a bundle (archive-of-archives) ─────────────────────────
# A bundle contains multiple .tar.gz files at the top level.
# An individual backup archive contains a folder with restore.sh, compose, etc.
info "  Inspecting archive: $(basename "$SOURCE_PATH")"

# List top-level contents of the archive
top_level_tarballs=0
top_level_dirs=0

while IFS= read -r entry; do
  # Normalize: strip trailing slash, get top-level component only
  top="$(echo "$entry" | cut -d'/' -f1)"

  if [[ "$entry" =~ \.tar\.gz$ ]] && [[ "$entry" == "$top" || "$entry" == "$top/" ]]; then
    # This is a .tar.gz file at the top level
    (( top_level_tarballs++ )) || true
  fi
done < <(tar -tzf "$SOURCE_PATH" 2>/dev/null | head -100)

# Count distinct top-level entries
distinct_top_levels="$(tar -tzf "$SOURCE_PATH" 2>/dev/null | cut -d'/' -f1 | sort -u | wc -l)"

# Heuristic: if the archive contains .tar.gz files at root level, it's a bundle.
# Also: if there are multiple distinct top-level directories, it's likely a bundle.
is_bundle=false
if (( top_level_tarballs >= 2 )); then
  is_bundle=true
elif (( distinct_top_levels > 1 )); then
  # Check if those top-level entries are .tar.gz files
  tarball_count="$(tar -tzf "$SOURCE_PATH" 2>/dev/null | grep -cE '^[^/]+\.tar\.gz$' || echo 0)"
  if (( tarball_count >= 2 )); then
    is_bundle=true
  fi
fi

# ── Case A: Archive-of-archives bundle ────────────────────────────────────────
if [[ "$is_bundle" == true ]]; then
  info "  Case A: Archive-of-archives bundle detected"

  if [[ "$DRY_RUN" == true ]]; then
    info "  [dry-run] would extract bundle to $WORK_DIR and delete: $(basename "$SOURCE_PATH")"
    exit 0
  fi

  # Extract the bundle into the work directory with progress
  extract_with_progress "$SOURCE_PATH" "$WORK_DIR" "$(basename "$SOURCE_PATH")"

  # Move any extracted .tar.gz files that ended up in subdirectories to the work dir root
  # (in case the bundle had a top-level wrapping directory)
  find "$WORK_DIR" -mindepth 2 -name "*.tar.gz" -exec mv {} "$WORK_DIR/" \; 2>/dev/null || true

  # Delete the original bundle
  rm -f "$SOURCE_PATH"
  ok "  Bundle extracted and original removed"
  exit 0
fi

# ── Case B: Individual restore archive ────────────────────────────────────────
info "  Case B: Individual restore archive detected"
archive_name="$(basename "$SOURCE_PATH")"
dest="$WORK_DIR/$archive_name"

if [[ "$DRY_RUN" == true ]]; then
  info "  [dry-run] would stage: $archive_name"
else
  # Move or copy the archive to the work directory
  if [[ "$(dirname "$(realpath "$SOURCE_PATH")")" == "$(realpath "$WORK_DIR")" ]]; then
    info "  Archive already in work directory"
  else
    cp "$SOURCE_PATH" "$dest"
    ok "  Staged: $archive_name"
  fi
fi
