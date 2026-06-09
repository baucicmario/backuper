#!/usr/bin/env bash
# modules/backup/steps/01b-select-containers.sh
# Display a terminal-based container selection interface using whiptail.
# Falls back to a simple numbered-list selector if whiptail is unavailable.
#
# All containers are selected by default.
# Supports: select all, deselect all, toggle individual entries.
#
# Usage: 01b-select-containers.sh <stack1_path:service1> <stack1_path:service2> ...
# Output: selected containers, one per line (stdout)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../../lib/common.sh"

CONTAINERS=("$@")

[[ ${#CONTAINERS[@]} -gt 0 ]] || die "No containers provided for selection"

# ── Try whiptail first ────────────────────────────────────────────────────────
if command -v whiptail >/dev/null 2>&1; then
  # Build whiptail checklist options
  OPTIONS=()
  for container in "${CONTAINERS[@]}"; do
    stack_path="${container%%:*}"
    service_name="${container#*:}"
    stack_name="$(basename "$stack_path")"
    display_name="$stack_name / $service_name"
    OPTIONS+=("$container" "$display_name" "ON")
  done

  # Calculate terminal dimensions
  term_height=$(tput lines 2>/dev/null || echo 24)
  term_width=$(tput cols 2>/dev/null || echo 80)
  list_height=$(( ${#CONTAINERS[@]} < (term_height - 8) ? ${#CONTAINERS[@]} : (term_height - 8) ))
  dialog_height=$(( list_height + 8 ))
  dialog_width=$(( term_width > 90 ? 90 : term_width - 4 ))

  # Show checklist (redirect stderr→stdout for whiptail output)
  raw_selection=$(whiptail \
    --title "Backup Container Selection" \
    --checklist \
    "Select containers to backup (SPACE = toggle, ENTER = confirm)\nTotal: ${#CONTAINERS[@]} containers" \
    "$dialog_height" "$dialog_width" "$list_height" \
    "${OPTIONS[@]}" \
    3>&1 1>&2 2>&3) || {
    warn "Selection cancelled — no containers will be backed up." >&2
    exit 0
  }

  # Parse whiptail output: quoted strings → strip quotes → split
  if [[ -z "$raw_selection" ]]; then
    warn "No containers selected." >&2
    exit 0
  fi

  while IFS= read -r selected; do
    [[ -n "$selected" ]] && echo "$selected"
  done < <(echo "$raw_selection" | tr -d '"' | tr ' ' '\n')
  exit 0
fi

# ── Fallback: numbered-list selector ──────────────────────────────────────────
warn "whiptail not available — using text-based selector" >&2

# Initialize all as selected
declare -A selection
for container in "${CONTAINERS[@]}"; do
  selection["$container"]=1
done

while true; do
  echo >&2
  bold "  Container Selection" >&2
  line >&2

  i=1
  for container in "${CONTAINERS[@]}"; do
    stack_path="${container%%:*}"
    service_name="${container#*:}"
    stack_name="$(basename "$stack_path")"
    display_name="$stack_name / $service_name"

    if [[ "${selection[$container]}" == "1" ]]; then
      echo -e "  ${GREEN}[$i] ✔ $display_name${RESET}" >&2
    else
      echo -e "  ${YELLOW}[$i] ✖ $display_name${RESET}" >&2
    fi
    (( i++ )) || true
  done

  # Count selected
  selected_count=0
  for container in "${CONTAINERS[@]}"; do
    [[ "${selection[$container]}" == "1" ]] && (( selected_count++ )) || true
  done
  echo >&2
  info "  ${selected_count}/${#CONTAINERS[@]} selected" >&2
  echo >&2
  echo "  Commands:  [number] toggle  |  [a] select all  |  [n] deselect all  |  [enter] confirm" >&2
  printf "  > " >&2
  read -r input </dev/tty

  case "$input" in
    "")
      # Confirm selection
      break
      ;;
    a|A)
      for container in "${CONTAINERS[@]}"; do selection["$container"]=1; done
      ;;
    n|N)
      for container in "${CONTAINERS[@]}"; do selection["$container"]=0; done
      ;;
    *[0-9]*)
      idx=$((input))
      if (( idx >= 1 && idx <= ${#CONTAINERS[@]} )); then
        target="${CONTAINERS[$((idx - 1))]}"
        if [[ "${selection[$target]}" == "1" ]]; then
          selection["$target"]=0
        else
          selection["$target"]=1
        fi
      else
        warn "  Invalid number: $input" >&2
      fi
      ;;
    *)
      warn "  Unknown command: $input" >&2
      ;;
  esac
done

# Output selected containers
for container in "${CONTAINERS[@]}"; do
  [[ "${selection[$container]}" == "1" ]] && echo "$container"
done
