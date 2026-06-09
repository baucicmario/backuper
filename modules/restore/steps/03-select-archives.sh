#!/usr/bin/env bash
# modules/restore/steps/03-select-archives.sh
# Display a terminal-based archive selection interface using whiptail.
# Falls back to a simple numbered-list selector if whiptail is unavailable.
#
# All archives are selected by default.
# Supports: select all, deselect all, toggle individual entries.
#
# Usage: 03-select-archives.sh <work_dir> <archive1> <archive2> ...
# Output: selected archive names, one per line (stdout)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../../lib/common.sh"

WORK_DIR="${1:?Usage: 03-select-archives.sh <work_dir> <archive1> ...}"
shift

ARCHIVES=("$@")

[[ ${#ARCHIVES[@]} -gt 0 ]] || die "No archives provided for selection"

# ── Try whiptail first ────────────────────────────────────────────────────────
if command -v whiptail >/dev/null 2>&1; then
  # Build whiptail checklist options
  OPTIONS=()
  for archive in "${ARCHIVES[@]}"; do
    archive_path="$WORK_DIR/$archive"
    size="$(stat -c%s "$archive_path" 2>/dev/null || stat -f%z "$archive_path" 2>/dev/null || echo 0)"
    size_human="$(fmt_size "$size")"
    OPTIONS+=("$archive" "$size_human" "ON")
  done

  # Calculate terminal dimensions
  term_height=$(tput lines 2>/dev/null || echo 24)
  term_width=$(tput cols 2>/dev/null || echo 80)
  list_height=$(( ${#ARCHIVES[@]} < (term_height - 8) ? ${#ARCHIVES[@]} : (term_height - 8) ))
  dialog_height=$(( list_height + 8 ))
  dialog_width=$(( term_width > 90 ? 90 : term_width - 4 ))

  # Show checklist (redirect stderr→stdout for whiptail output)
  raw_selection=$(whiptail \
    --title "Restore Archive Selection" \
    --checklist \
    "Select archives to restore (SPACE = toggle, ENTER = confirm)
Total: ${#ARCHIVES[@]} archives" \
    "$dialog_height" "$dialog_width" "$list_height" \
    "${OPTIONS[@]}" \
    3>&1 1>&2 2>&3) || {
    warn "Selection cancelled — no archives will be restored." >&2
    exit 0
  }

  # Parse whiptail output: quoted strings → strip quotes → split
  if [[ -z "$raw_selection" ]]; then
    warn "No archives selected." >&2
    exit 0
  fi

  # whiptail returns "file1.tar.gz" "file2.tar.gz" — parse carefully
  while IFS= read -r selected; do
    [[ -n "$selected" ]] && echo "$selected"
  done < <(echo "$raw_selection" | tr -d '"' | tr ' ' '\n')
  exit 0
fi

# ── Fallback: numbered-list selector ──────────────────────────────────────────
warn "whiptail not available — using text-based selector" >&2

# Initialize all as selected
declare -A selection
for archive in "${ARCHIVES[@]}"; do
  selection["$archive"]=1
done

while true; do
  echo >&2
  bold "  Archive Selection" >&2
  line >&2

  i=1
  for archive in "${ARCHIVES[@]}"; do
    archive_path="$WORK_DIR/$archive"
    size="$(stat -c%s "$archive_path" 2>/dev/null || stat -f%z "$archive_path" 2>/dev/null || echo 0)"
    size_human="$(fmt_size "$size")"

    if [[ "${selection[$archive]}" == "1" ]]; then
      echo -e "  ${GREEN}[$i] ✔ $archive${RESET}  ($size_human)" >&2
    else
      echo -e "  ${YELLOW}[$i] ✖ $archive${RESET}  ($size_human)" >&2
    fi
    (( i++ )) || true
  done

  # Count selected
  selected_count=0
  for archive in "${ARCHIVES[@]}"; do
    [[ "${selection[$archive]}" == "1" ]] && (( selected_count++ )) || true
  done
  echo >&2
  info "  ${selected_count}/${#ARCHIVES[@]} selected" >&2
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
      for archive in "${ARCHIVES[@]}"; do selection["$archive"]=1; done
      ;;
    n|N)
      for archive in "${ARCHIVES[@]}"; do selection["$archive"]=0; done
      ;;
    *[0-9]*)
      idx=$((input))
      if (( idx >= 1 && idx <= ${#ARCHIVES[@]} )); then
        target="${ARCHIVES[$((idx - 1))]}"
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

# Output selected archives
for archive in "${ARCHIVES[@]}"; do
  [[ "${selection[$archive]}" == "1" ]] && echo "$archive"
done
