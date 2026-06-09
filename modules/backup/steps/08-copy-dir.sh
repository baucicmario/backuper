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

# Try tar|pv pipeline for precise progress tracking
if command -v pv >/dev/null 2>&1; then
  size_bytes=$(du -sb "$SRC" 2>/dev/null | cut -f1 || echo "0")
  size_mb=$(( size_bytes / 1024 / 1024 ))
  echo "[job-sub_total: $size_mb]"
  
  if [[ "$size_bytes" -gt 0 ]]; then
    # We pipe stderr of tar to the temp file
    # pv's stdout (data) goes to tar xf (via fd 3)
    # pv's stderr (progress) goes to awk, which outputs to the script's original stdout (fd 5)
    exec 5>&1
    if tar cf - -C "$SRC" . 2>"$stderr_file" | ( pv -n -f -s "$size_bytes" 2>&1 1>&3 | awk '{print "[pv: "$1"]"; fflush()}' >&5 ) 3>&1 | tar xf - -C "$DST" 2>>"$stderr_file"; then
      exec 5>&-
      ok "Copied: $SRC → $DST"
      rm -f "$stderr_file"; exit 0
    fi
    exec 5>&-
  else
    if cp -a "$SRC/." "$DST/" 2>"$stderr_file"; then
      ok "Copied: $SRC → $DST"
      rm -f "$stderr_file"; exit 0
    fi
  fi
else
  # Fallback to cp without progress tracking
  size_mb=$(du -sm "$SRC" 2>/dev/null | cut -f1 || echo "0")
  echo "[job-sub_total: $size_mb]"
  if cp -a "$SRC/." "$DST/" 2>"$stderr_file"; then
    ok "Copied: $SRC → $DST"
    rm -f "$stderr_file"; exit 0
  fi
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