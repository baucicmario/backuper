#!/usr/bin/env bash
# phase0.sh — Run all scripts in phase-0/ in sorted order.
# Usage: ./phase0.sh [--exclude <glob>] [--no-skip-disabled] [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PHASE0_DIR="$SCRIPT_DIR/phase-0"

[ -d "$PHASE0_DIR" ] || { echo "Error: phase-0 directory not found: $PHASE0_DIR" >&2; exit 1; }

source "$SCRIPT_DIR/lib/common.sh"

# ── Argument parsing ──────────────────────
EXCLUDES=()
SKIP_DISABLED=true
DRY_RUN=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --exclude)
      shift
      [ -n "${1:-}" ] || { echo "--exclude requires a glob argument" >&2; exit 2; }
      EXCLUDES+=("$1")
      ;;
    --no-skip-disabled) SKIP_DISABLED=false ;;
    --dry-run)          DRY_RUN=true ;;
    --help|-h)
      cat <<USAGE
Usage: $0 [options]

Options:
  --exclude <glob>        Skip scripts matching this glob (basename). Repeatable.
  --no-skip-disabled      Run scripts with .disabled / DISABLED_ markers too.
  --dry-run               Print what would run without actually executing anything.
  -h, --help              Show this help.
USAGE
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

info "➡  Running Phase 0 scripts from: $PHASE0_DIR"
[ "$DRY_RUN" = true ] && warn "DRY RUN — no scripts will actually execute"

# ── Discover scripts ──────────────────────
mapfile -t SCRIPTS < <(find "$PHASE0_DIR" -maxdepth 1 -type f -name "*.sh" | sort -V)

[ ${#SCRIPTS[@]} -gt 0 ] || { warn "No .sh scripts found in $PHASE0_DIR"; exit 0; }

# ── Run each script ───────────────────────
for script in "${SCRIPTS[@]}"; do
  [ -f "$script" ] || continue
  name="$(basename "$script")"

  # Skip disabled variants
  if [ "$SKIP_DISABLED" = true ]; then
    case "$name" in
      *.disabled.sh|*.sh.disabled|DISABLED_*|*_disabled.sh)
        echo
        line
        warn "Skipping disabled: $script"
        line
        continue ;;
    esac
  fi

  # Skip excluded globs
  skip=false
  for pat in "${EXCLUDES[@]}"; do
    [[ "$name" == $pat ]] && { skip=true; break; }
  done
  if [ "$skip" = true ]; then
    echo
    line
    warn "Excluded by pattern, skipping: $script"
    line
    continue
  fi

  echo
  line
  info "Running: $script"
  line

  if [ "$DRY_RUN" = true ]; then
    info "(dry-run) Would execute: bash $script"
    continue
  fi

  if bash "$script"; then
    ok "Completed: $name"
  else
    error "Failed: $name"
    exit 1
  fi
done

echo
[ "$DRY_RUN" = true ] \
  && ok "Dry run complete — no scripts were executed." \
  || ok "🎉 All phase 0 scripts executed successfully."