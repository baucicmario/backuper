#!/usr/bin/env bash
# tasks/07-copy-dir.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

SRC="${1:?Usage: $0 <src> <dst>}"
DST="${2:?}"

if [[ ! -d "$SRC" ]]; then
  warn "Source directory not found: $SRC"
  exit 0
fi

mkdir -p "$DST"
stderr_file="$(mktemp)"

# Attempt 1: full archive
if cp -a "$SRC/." "$DST/" 2>"$stderr_file"; then
  ok "Copied: $SRC → $DST"
  rm -f "$stderr_file"; exit 0
fi

# Attempt 2: data-only (NTFS/WSL metadata not supported)
if grep -qE 'preserving (times|permissions|ownership)' "$stderr_file"; then
  info "  (destination does not support metadata — retrying data-only)"
  if cp -r "$SRC/." "$DST/" 2>"$stderr_file"; then
    ok "Copied (data only): $SRC → $DST"
    rm -f "$stderr_file"; exit 0
  fi
  if grep -qE 'preserving (times|permissions|ownership)' "$stderr_file"; then
    ok "Copied (data only): $SRC → $DST"
    rm -f "$stderr_file"; exit 0
  fi
fi

# Attempt 3: permission denied — retry with sudo
if grep -q 'Permission denied' "$stderr_file"; then
  info "  (permission denied — retrying with sudo)"
  if sudo cp -r "$SRC/." "$DST/" 2>"$stderr_file"; then
    ok "Copied (sudo): $SRC → $DST"
    rm -f "$stderr_file"; exit 0
  fi
fi

# All attempts failed — warn and continue
warn "Could not copy: $SRC → $DST"
cat "$stderr_file" >&2
rm -f "$stderr_file"
exit 0