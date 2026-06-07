#!/usr/bin/env bash
# phase1.sh — Run all scripts in phase-1/ in sorted order.
# Usage: ./phase1.sh [--exclude <glob>] [--no-skip-disabled] [--dry-run]
#
# Any extra flags after -- are forwarded as-is to every phase-1 script.
# Example: ./phase1.sh -- --stacks-dir /mnt/stacks --output /tmp/split
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PHASE1_DIR="$SCRIPT_DIR/phase-1"

[ -d "$PHASE1_DIR" ] || { echo "Error: phase-1 directory not found: $PHASE1_DIR" >&2; exit 1; }

source "$SCRIPT_DIR/lib/common.sh"

# ── Argument parsing ──────────────────────
EXCLUDES=()
SKIP_DISABLED=true
DRY_RUN=false
FORWARD_ARGS=()   # collected after --

while [ "$#" -gt 0 ]; do
  case "$1" in
    --exclude)
      shift
      [ -n "${1:-}" ] || { echo "--exclude requires a glob argument" >&2; exit 2; }
      EXCLUDES+=("$1")
      ;;
    --no-skip-disabled) SKIP_DISABLED=false ;;
    --dry-run)          DRY_RUN=true ;;
    --)
      shift
      # Everything after -- is forwarded verbatim to each phase-1 script
      FORWARD_ARGS+=("$@")
      break
      ;;
    --help|-h)
      cat <<USAGE
Usage: $0 [options] [-- <script-args>]

Options:
  --exclude <glob>        Skip scripts matching this glob (basename). Repeatable.
  --no-skip-disabled      Run scripts with .disabled / DISABLED_ markers too.
  --dry-run               Print what would run without actually executing anything.
  -h, --help              Show this help.

Script forwarding:
  Any arguments after -- are passed through to every phase-1 script.
  Example: $0 -- --stacks-dir /mnt/stacks --output /tmp/split --dry-run
USAGE
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

info "➡  Running Phase 1 scripts from: $PHASE1_DIR"
[ "$DRY_RUN" = true ]          && warn "DRY RUN — no scripts will actually execute"
[ ${#FORWARD_ARGS[@]} -gt 0 ]  && info "Forwarding to scripts: ${FORWARD_ARGS[*]}"

# ── Discover scripts ──────────────────────
mapfile -t SCRIPTS < <(find "$PHASE1_DIR" -maxdepth 1 -type f -name "*.sh" | sort -V)

[ ${#SCRIPTS[@]} -gt 0 ] || { warn "No .sh scripts found in $PHASE1_DIR"; exit 0; }

# ── Run each script ───────────────────────
for script in "${SCRIPTS[@]}"; do
  [ -f "$script" ] || continue
  name="$(basename "$script")"

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
  [ ${#FORWARD_ARGS[@]} -gt 0 ] && info "  Args : ${FORWARD_ARGS[*]}"
  line

  if [ "$DRY_RUN" = true ]; then
    info "(dry-run) Would execute: bash $script${FORWARD_ARGS[*]:+ ${FORWARD_ARGS[*]}}"
    continue
  fi

  if bash "$script" "${FORWARD_ARGS[@]}"; then
    ok "Completed: $name"
  else
    error "Failed: $name"
    exit 1
  fi
done

echo
[ "$DRY_RUN" = true ] \
  && ok "Dry run complete — no scripts were executed." \
  || ok "🎉 All phase 1 scripts executed successfully."
