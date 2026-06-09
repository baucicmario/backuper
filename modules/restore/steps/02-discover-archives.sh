#!/usr/bin/env bash
# modules/restore/steps/02-discover-archives.sh
# Scan a directory for .tar.gz restore archives and print their names.
#
# Output: one archive filename per line (stdout), sorted alphabetically.
# Diagnostic messages go to stderr so the orchestrator can capture filenames cleanly.
#
# Usage: 02-discover-archives.sh <work_dir>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../../lib/common.sh"

WORK_DIR="${1:?Usage: 02-discover-archives.sh <work_dir>}"

[[ -d "$WORK_DIR" ]] || die "Work directory not found: $WORK_DIR"

count=0
while IFS= read -r -d '' archive; do
  if is_archive_bundle "$archive"; then
    continue
  fi
  name="$(basename "$archive")"
  size="$(stat -c%s "$archive" 2>/dev/null || stat -f%z "$archive" 2>/dev/null || echo 0)"
  info "  Found: $name  ($(fmt_size "$size"))" >&2
  echo "$name"
  (( count++ )) || true
done < <(find "$WORK_DIR" -maxdepth 1 -type f -name "*.tar.gz" -print0 | sort -z)

if [[ $count -eq 0 ]]; then
  warn "No .tar.gz archives found in $WORK_DIR" >&2
fi
