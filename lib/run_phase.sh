#!/usr/bin/env bash
set -euo pipefail

SCRIPT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_LIB/common.sh"

run_phase() {
  local PHASE_DIR="$1"
  local PHASE_LABEL="$2"
  shift 2

  [ -d "$PHASE_DIR" ] || { echo "Error: directory not found: $PHASE_DIR" >&2; exit 1; }

  local EXCLUDES=() SKIP_DISABLED=true DRY_RUN=false FORWARD_ARGS=()

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

  info "➡  Running $PHASE_LABEL scripts from: $PHASE_DIR"
  [ "$DRY_RUN" = true ] && warn "DRY RUN — no scripts will actually execute"
  [ ${#FORWARD_ARGS[@]} -gt 0 ] && info "Forwarding to scripts: ${FORWARD_ARGS[*]}"

  mapfile -t SCRIPTS < <(find "$PHASE_DIR" -maxdepth 1 -type f -name "*.sh" | sort -V)
  [ ${#SCRIPTS[@]} -gt 0 ] || { warn "No .sh scripts found in $PHASE_DIR"; return 0; }

  for script in "${SCRIPTS[@]}"; do
    [ -f "$script" ] || continue
    local name; name="$(basename "$script")"

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

    echo; line
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
  [ "$DRY_RUN" = true ] && ok "Dry run complete — no scripts were executed." || ok "🎉 All $PHASE_LABEL scripts executed successfully."
}