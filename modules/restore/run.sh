#!/usr/bin/env bash
# modules/restore/run.sh — Headless restore orchestrator.
# Coordinates the complete restore workflow:
#   intake → discover → select → extract → restore → cleanup → summary
#
# Usage:
#   run.sh <path>                           — archive, bundle, or directory
#   run.sh <path> --work-dir /tmp/restore   — explicit work directory
#   run.sh <path> --select-all              — skip selection, restore everything
#   run.sh <path> --archives a.tar.gz b.tar.gz — non-interactive archive list
#   run.sh <path> --dry-run                 — show what would happen
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

# Shorthand for steps directory
S="$SCRIPT_DIR/steps"

# ── Parse arguments ───────────────────────────────────────────────────────────
SOURCE_PATH=""
WORK_DIR=""
SELECT_ALL=false
DRY_RUN=false
EXPLICIT_ARCHIVES=()
ORIGINAL_SOURCES=()  # Track original source file paths for cleanup prompt

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir)     shift; WORK_DIR="$1" ;;
    --select-all)   SELECT_ALL=true ;;
    --no-prompts)   NO_PROMPTS=true ;;
    --dry-run)      DRY_RUN=true ;;
    --archives)
      shift
      while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
        EXPLICIT_ARCHIVES+=("$1")
        shift
      done
      continue  # Don't shift again at the bottom
      ;;
    --help|-h)
      echo "Usage: restore.sh <path> [options]"
      echo ""
      echo "  <path>                     Archive (.tar.gz), bundle, or directory"
      echo ""
      echo "Options:"
      echo "  --work-dir <dir>           Override the restore work directory"
      echo "  --select-all               Skip selection UI, restore all archives"
      echo "  --archives <f1> <f2> ...   Restore only the specified archives"
      echo "  --dry-run                  Show what would happen without executing"
      echo "  --help                     Show this help message"
      exit 0
      ;;
    -*)
      die "Unknown flag: $1 (use --help for usage)"
      ;;
    *)
      # First positional argument is the source path
      if [[ -z "$SOURCE_PATH" ]]; then
        SOURCE_PATH="$1"
      else
        die "Unexpected argument: $1 (source path already set to '$SOURCE_PATH')"
      fi
      ;;
  esac
  shift
done

[[ -n "$SOURCE_PATH" ]] || die "No source path provided. Usage: restore.sh <path> [options]"

# ── Banner ────────────────────────────────────────────────────────────────────
echo
bold "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
bold "${GREEN}  🔄  Backuper — Headless Restore                ${RESET}"
bold "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo

[[ "$DRY_RUN" == true ]] && warn "DRY RUN — no changes will be made"

# ── Ensure dependencies ──────────────────────────────────────────────────────
ensure_restore_deps

# ── Resolve work directory ───────────────────────────────────────────────────
if [[ -z "$WORK_DIR" ]]; then
  WORK_BASE="$(choose_work_dir 500)"
  WORK_DIR="$(mktemp -d "$WORK_BASE/backuper-restore-XXXX")"
  info "Work directory: $WORK_DIR"
else
  mkdir -p "$WORK_DIR"
  info "Work directory (explicit): $WORK_DIR"
fi

# Ensure cleanup on exit
CLEANUP_WORK_DIR=true
cleanup_on_exit() {
  if [[ "$CLEANUP_WORK_DIR" == true && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR" 2>/dev/null || true
  fi
}
trap cleanup_on_exit EXIT

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — Intake: stage archives into work directory
# ══════════════════════════════════════════════════════════════════════════════
line
bold "STEP 1 — Archive Intake"
line

# Intake loop: process the initial source, then ask for more
bash "$S/01-intake.sh" "$SOURCE_PATH" "$WORK_DIR" "$DRY_RUN"
if [[ -f "$SOURCE_PATH" ]]; then
  ORIGINAL_SOURCES+=("$(realpath "$SOURCE_PATH")")
elif [[ -d "$SOURCE_PATH" ]]; then
  while IFS= read -r -d '' archive; do
    ORIGINAL_SOURCES+=("$(realpath "$archive")")
  done < <(find "$SOURCE_PATH" -maxdepth 1 -type f -name "*.tar.gz" -print0 | sort -z)
fi

if [[ "${NO_PROMPTS:-false}" == true ]]; then
  info "Skipping additional archive prompt (--no-prompts)"
else
  while confirm_prompt "Do you want to add another archive or directory?"; do
    echo
    printf "  Enter path to archive or directory: "
    read -r ADDITIONAL_PATH </dev/tty
    if [[ -z "$ADDITIONAL_PATH" ]]; then
      warn "  No path entered — skipping"
      continue
    fi
    if [[ ! -e "$ADDITIONAL_PATH" ]]; then
      warn "  Path not found: $ADDITIONAL_PATH — skipping"
      continue
    fi
    bash "$S/01-intake.sh" "$ADDITIONAL_PATH" "$WORK_DIR" "$DRY_RUN"
    if [[ -f "$ADDITIONAL_PATH" ]]; then
      ORIGINAL_SOURCES+=("$(realpath "$ADDITIONAL_PATH")")
    elif [[ -d "$ADDITIONAL_PATH" ]]; then
      while IFS= read -r -d '' archive; do
        ORIGINAL_SOURCES+=("$(realpath "$archive")")
      done < <(find "$ADDITIONAL_PATH" -maxdepth 1 -type f -name "*.tar.gz" -print0 | sort -z)
    fi
  done
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — Discover archives in work directory
# ══════════════════════════════════════════════════════════════════════════════
echo
line
bold "STEP 2 — Archive Discovery"
line

mapfile -t ALL_ARCHIVES < <(bash "$S/02-discover-archives.sh" "$WORK_DIR")

if [[ ${#ALL_ARCHIVES[@]} -eq 0 ]]; then
  warn "No .tar.gz archives found in $WORK_DIR"
  ok "Nothing to restore."
  exit 0
fi

info "Found ${#ALL_ARCHIVES[@]} archive(s) in work directory"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Archive selection
# ══════════════════════════════════════════════════════════════════════════════
echo
line
bold "STEP 3 — Archive Selection"
line

SELECTED_ARCHIVES=()

if [[ ${#EXPLICIT_ARCHIVES[@]} -gt 0 ]]; then
  # Non-interactive: use explicitly provided archive names
  info "Using explicitly provided archive list (${#EXPLICIT_ARCHIVES[@]} archives)"
  for name in "${EXPLICIT_ARCHIVES[@]}"; do
    # Find matching archive in work dir
    if [[ -f "$WORK_DIR/$name" ]]; then
      SELECTED_ARCHIVES+=("$name")
    else
      warn "Archive not found in work dir: $name — skipping"
    fi
  done
elif [[ "$SELECT_ALL" == true ]]; then
  # Non-interactive: select all
  info "Selecting all archives (--select-all)"
  SELECTED_ARCHIVES=("${ALL_ARCHIVES[@]}")
else
  # Interactive: whiptail selection
  mapfile -t SELECTED_ARCHIVES < <(bash "$S/03-select-archives.sh" "$WORK_DIR" "${ALL_ARCHIVES[@]}")
fi

if [[ ${#SELECTED_ARCHIVES[@]} -eq 0 ]]; then
  warn "No archives selected for restoration."
  ok "Nothing to restore."
  exit 0
fi

info "Selected ${#SELECTED_ARCHIVES[@]} of ${#ALL_ARCHIVES[@]} archive(s) for restoration"
echo

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3.5 — Clean up unselected archives
# ══════════════════════════════════════════════════════════════════════════════
UNSELECTED_COUNT=0
for archive in "${ALL_ARCHIVES[@]}"; do
  is_selected=false
  for sel in "${SELECTED_ARCHIVES[@]}"; do
    [[ "$archive" == "$sel" ]] && { is_selected=true; break; }
  done
  if [[ "$is_selected" == false ]]; then
    archive_path="$WORK_DIR/$archive"
    if [[ "$DRY_RUN" == true ]]; then
      info "  [dry-run] would remove unselected: $archive"
    else
      rm -f "$archive_path" 2>/dev/null || true
    fi
    (( UNSELECTED_COUNT++ )) || true
  fi
done
[[ $UNSELECTED_COUNT -gt 0 ]] && info "Removed $UNSELECTED_COUNT unselected archive(s)"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 & 5 — Extract and restore each selected archive
# ══════════════════════════════════════════════════════════════════════════════
echo
line
bold "STEP 4 — Restore Execution"
line

TOTAL=${#SELECTED_ARCHIVES[@]}
COMPLETED=0
SUCCEEDED=0
FAILED=0
RESULTS_OK=()
RESULTS_FAIL=()

for archive_name in "${SELECTED_ARCHIVES[@]}"; do
  (( COMPLETED++ )) || true
  archive_path="$WORK_DIR/$archive_name"

  echo
  bold "  ┌─ Archive $COMPLETED of $TOTAL ─────────────────────────────────"
  info "  │  $archive_name"
  bold "  └────────────────────────────────────────────────────────"

  # Overall progress
  pct=$(( (COMPLETED - 1) * 100 / TOTAL ))
  info "  Overall progress: $pct% ($((COMPLETED - 1))/$TOTAL completed)"

  if [[ ! -f "$archive_path" ]]; then
    warn "  Archive not found: $archive_path — skipping"
    RESULTS_FAIL+=("$archive_name (not found)")
    (( FAILED++ )) || true
    continue
  fi

  if [[ "$DRY_RUN" == true ]]; then
    info "  [dry-run] would extract and restore: $archive_name"
    RESULTS_OK+=("$archive_name (dry-run)")
    (( SUCCEEDED++ )) || true
    continue
  fi

  # ── Extract ───────────────────────────────────────────────────────────
  extracted_dir=""
  if extracted_dir="$(bash "$S/04-extract-archive.sh" "$archive_path" "$WORK_DIR")"; then
    ok "  Extraction complete: $archive_name"
  else
    error "  Extraction failed: $archive_name"
    RESULTS_FAIL+=("$archive_name (extraction failed)")
    (( FAILED++ )) || true
    continue
  fi

  # ── Restore ──────────────────────────────────────────────────────────
  if bash "$S/05-run-restore.sh" "$extracted_dir"; then
    if [[ -f "$WORK_DIR/.warning_$archive_name" ]]; then
      RESULTS_OK+=("$archive_name ${YELLOW}(Hardware device nodes safely skipped)${RESET}")
    else
      RESULTS_OK+=("$archive_name")
    fi
    ok "  Restore complete: $archive_name"
    (( SUCCEEDED++ )) || true
  else
    error "  Restore failed: $archive_name"
    RESULTS_FAIL+=("$archive_name (restore.sh failed)")
    (( FAILED++ )) || true
  fi

  # ── Cleanup ──────────────────────────────────────────────────────────
  bash "$S/06-cleanup.sh" "$extracted_dir" "$archive_path"
done

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — Final Summary
# ══════════════════════════════════════════════════════════════════════════════
echo
echo
bold "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
bold "${GREEN}  📋  Restore Summary                            ${RESET}"
bold "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo

# Statistics
bold "  Statistics:"
echo -e "    Total discovered  : ${#ALL_ARCHIVES[@]}"
echo -e "    Selected          : $TOTAL"
echo -e "    ${GREEN}Succeeded${RESET}       : $SUCCEEDED"
[[ $FAILED -gt 0 ]] && echo -e "    ${RED}Failed${RESET}          : $FAILED"
[[ $UNSELECTED_COUNT -gt 0 ]] && echo -e "    Skipped         : $UNSELECTED_COUNT"
echo

# Restored archives
if [[ ${#RESULTS_OK[@]} -gt 0 ]]; then
  bold "  ${GREEN}✅ Restored:${RESET}"
  for r in "${RESULTS_OK[@]}"; do
    echo -e "    ${GREEN}✔${RESET} $r"
  done
  echo
fi

# Failed archives
if [[ ${#RESULTS_FAIL[@]} -gt 0 ]]; then
  bold "  ${RED}❌ Failed:${RESET}"
  for r in "${RESULTS_FAIL[@]}"; do
    echo -e "    ${RED}✖${RESET} $r"
  done
  echo
fi

# Cleanup status
if [[ "$DRY_RUN" == true ]]; then
  info "  Cleanup: skipped (dry-run)"
else
  ok "  Cleanup: work directory will be removed on exit"
fi

# ── Prompt to delete original source archives ────────────────────────────────
# Filter to only files that still exist AND were successfully restored
EXISTING_SOURCES=()
for src in "${ORIGINAL_SOURCES[@]}"; do
  src_basename="$(basename "$src")"
  for restored in "${RESULTS_OK[@]}"; do
    restored_clean="${restored% (dry-run)}"
    if [[ "$src_basename" == "$restored_clean" ]]; then
      [[ -f "$src" ]] && EXISTING_SOURCES+=("$src")
      break
    fi
  done
done

# Sort and make unique just in case
if [[ ${#EXISTING_SOURCES[@]} -gt 0 ]]; then
  mapfile -t EXISTING_SOURCES < <(printf "%s\n" "${EXISTING_SOURCES[@]}" | sort -u)
fi

if [[ ${#EXISTING_SOURCES[@]} -gt 0 ]]; then
  echo
  line
  if [[ "$DRY_RUN" == true ]]; then
    bold "  [dry-run] Original source archive(s) that would be prompted for deletion:"
    for src in "${EXISTING_SOURCES[@]}"; do
      local_size="$(stat -c%s "$src" 2>/dev/null || stat -f%z "$src" 2>/dev/null || echo 0)"
      echo -e "    ${YELLOW}•${RESET} $src  ($(fmt_size "$local_size"))"
    done
  else
    bold "  Original source archive(s) of successfully restored services:"
    for src in "${EXISTING_SOURCES[@]}"; do
      local_size="$(stat -c%s "$src" 2>/dev/null || stat -f%z "$src" 2>/dev/null || echo 0)"
      echo -e "    ${YELLOW}•${RESET} $src  ($(fmt_size "$local_size"))"
    done
    echo
    if [[ "${NO_PROMPTS:-false}" == true ]]; then
      info "  Keeping original source archive(s) (--no-prompts)"
    else
      if confirm_prompt "Delete these original source archive(s)?"; then
        for src in "${EXISTING_SOURCES[@]}"; do
          rm -f "$src" && ok "  Deleted: $src" || warn "  Could not delete: $src"
        done
      else
        info "  Keeping original source archive(s)"
      fi
    fi
  fi
fi

echo
bold "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

# Exit with non-zero if any failures
[[ $FAILED -eq 0 ]] && exit 0 || exit 1
