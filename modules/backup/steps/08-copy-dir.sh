#!/usr/bin/env bash
# tasks/08-copy-dir.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../../lib/common.sh"

SRC="${1:?Usage: $0 <src> <dst>}"
DST="${2:?}"

if [[ ! -d "$SRC" ]]; then
  warn "Source directory not found: $SRC"
  exit 0
fi

mkdir -p "$DST"
stderr_file="$(mktemp)"

if cp -a "$SRC/." "$DST/" 2>"$stderr_file"; then
  ok "Copied: $SRC → $DST"
  rm -f "$stderr_file"; exit 0
fi

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

if grep -q 'Permission denied' "$stderr_file"; then
  info "  (permission denied — retrying with sudo)"
  if sudo cp -r "$SRC/." "$DST/" 2>"$stderr_file"; then
    ok "Copied (sudo): $SRC → $DST"
    rm -f "$stderr_file"; exit 0
  fi
fi

warn "Could not copy: $SRC → $DST"
cat "$stderr_file" >&2
rm -f "$stderr_file"
exit 0