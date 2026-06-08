#!/usr/bin/env bash
# lib/runner.sh — Phase execution framework
# Provides the run_phase function that discovers and executes all scripts
# in a directory in sorted order, with support for exclusions and dry-runs.
set -euo pipefail

SCRIPT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_LIB/common.sh"

# ── Main phase execution function ─────────────────────────────────────────────
# Discovers all .sh files in a directory and runs them in sorted order.
# Supports flags like --exclude, --dry-run, --no-skip-disabled
run_phase() {
  local PHASE_DIR="$1"  # Directory containing scripts to run
  local PHASE_LABEL="$2"  # Human-readable phase name
  shift 2

  [ -d "$PHASE_DIR" ] || { echo "Error: directory not found: $PHASE_DIR" >&2; exit 1; }

  # Parse command-line flags
  local EXCLUDES=() SKIP_DISABLED=true DRY_RUN=false FORWARD_ARGS=()

  # Process flag arguments
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --exclude) shift; EXCLUDES+=("$1") ;;
      --no-skip-disabled) SKIP_DISABLED=false ;;
      --dry-run) DRY_RUN=true ;;
      --) shift; FORWARD_ARGS+=("$@"); break ;;
      --help|-h)
        echo "Usage: $PHASE_LABEL [--exclude <glob>] [--no-skip-disabled] [--dry-run] [-- <args>]"
        exit 0
        ;;
      *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
  done

  # Announce which phase is running
  info "➡  Running $PHASE_LABEL scripts from: $PHASE_DIR"
  [ "$DRY_RUN" = true ] && warn "DRY RUN — no scripts will actually execute"
  [ ${#FORWARD_ARGS[@]} -gt 0 ] && info "Forwarding to scripts: ${FORWARD_ARGS[*]}"

  # Find all .sh scripts in this phase directory, sorted numerically
  mapfile -t SCRIPTS < <(find "$PHASE_DIR" -maxdepth 1 -type f -name "*.sh" | sort -V)
  [ ${#SCRIPTS[@]} -gt 0 ] || { warn "No .sh scripts found in $PHASE_DIR"; return 0; }

  # Execute each script in order
  for script in "${SCRIPTS[@]}"; do
    [ -f "$script" ] || continue
    local name; name="$(basename "$script")"

    # Skip disabled scripts unless explicitly requested
    if [ "$SKIP_DISABLED" = true ]; then
      case "$name" in
        *.disabled.sh|*.sh.disabled|DISABLED_*|*_disabled.sh)
          echo; line; warn "Skipping disabled: $script"; line; continue ;;
      esac
    fi

    local skip=false
    for pat in "${EXCLUDES[@]}"; do
      [[ "$name" == $pat ]] && { skip=true; break; }
    done
    if [ "$skip" = true ]; then
      echo; line; warn "Excluded by pattern, skipping: $script"; line; continue
    fi

    # Print script header
    echo; line
    info "Running: $script"
    [ ${#FORWARD_ARGS[@]} -gt 0 ] && info "  Args : ${FORWARD_ARGS[*]}"
    line

    # In dry-run mode, just show what would execute
    if [ "$DRY_RUN" = true ]; then
      info "(dry-run) Would execute: bash $script${FORWARD_ARGS[*]:+ ${FORWARD_ARGS[*]}}"
      continue
    fi

    # Execute the script with any forwarded arguments
    if bash "$script" "${FORWARD_ARGS[@]}"; then
      ok "Completed: $name"
    else
      error "Failed: $name"
      exit 1  # Stop on first failure
    fi
  done

  echo
  # Print final summary
  [ "$DRY_RUN" = true ] && ok "Dry run complete — no scripts were executed." || ok "🎉 All $PHASE_LABEL scripts executed successfully."
}