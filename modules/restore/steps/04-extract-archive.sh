#!/usr/bin/env bash
# modules/restore/steps/04-extract-archive.sh
# Extract a single .tar.gz archive into the work directory with progress.
#
# Outputs the path to the extracted directory (stdout) for the orchestrator.
# All diagnostic output goes to stderr.
#
# Usage: 04-extract-archive.sh <archive_path> <work_dir>
# Output: absolute path to the extracted directory (stdout)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../../lib/common.sh"

ARCHIVE_PATH="${1:?Usage: 04-extract-archive.sh <archive_path> <work_dir>}"
WORK_DIR="${2:?}"

[[ -f "$ARCHIVE_PATH" ]] || die "Archive not found: $ARCHIVE_PATH"

archive_name="$(basename "$ARCHIVE_PATH")"
folder_name="${archive_name%.tar.gz}"

# ── Extract with progress ─────────────────────────────────────────────────────
extract_with_progress "$ARCHIVE_PATH" "$WORK_DIR" "$archive_name" >&2

# ── Locate the extracted directory ────────────────────────────────────────────
# Archives created by backuper have a single top-level directory matching the
# archive name (e.g., players__jellyfin.tar.gz → players__jellyfin/).
# Handle both cases: extracted as $WORK_DIR/$folder_name or as
# $WORK_DIR/$folder_name/$folder_name (double-nested from some tar behaviors).

extracted_dir="$WORK_DIR/$folder_name"

if [[ -d "$extracted_dir/$folder_name" ]] && [[ -f "$extracted_dir/$folder_name/restore.sh" || -f "$extracted_dir/$folder_name/docker-compose.yml" ]]; then
  # Double-nested: the archive had a top-level dir matching its name
  extracted_dir="$extracted_dir/$folder_name"
fi

if [[ ! -d "$extracted_dir" ]]; then
  # Try to find any directory that was just created
  # (in case the archive's internal structure doesn't match its filename)
  found_dir=""
  while IFS= read -r -d '' dir; do
    dir_name="$(basename "$dir")"
    # Skip hidden dirs and the archive file itself
    [[ "$dir_name" == .* ]] && continue
    if [[ -f "$dir/restore.sh" || -f "$dir/docker-compose.yml" ]]; then
      found_dir="$dir"
      break
    fi
  done < <(find "$WORK_DIR" -mindepth 1 -maxdepth 2 -type d -newer "$ARCHIVE_PATH" -print0 2>/dev/null || true)

  if [[ -n "$found_dir" ]]; then
    extracted_dir="$found_dir"
  else
    die "Could not locate extracted directory for $archive_name"
  fi
fi

ok "  Extracted to: $extracted_dir" >&2
echo "$extracted_dir"
