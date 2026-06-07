#!/usr/bin/env bash
set -euo pipefail

# Run all scripts in "phase 0" in numeric order (by filename or folder name)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PHASE0_DIR="$SCRIPT_DIR/phase-0"

if [ ! -d "$PHASE0_DIR" ]; then
  echo "Error: phase 0 directory not found at: $PHASE0_DIR"
  exit 1
fi


echo "➡ Running Phase 0 scripts from: $PHASE0_DIR"

# Parse args: allow multiple --exclude patterns (glob-style)
EXCLUDES=()
SKIP_DISABLED=true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --exclude)
      shift
      EXCLUDES+=("$1")
      ;;
    --no-skip-disabled)
      SKIP_DISABLED=false
      ;;
    --help|-h)
      echo "Usage: $0 [--exclude <glob>] [--no-skip-disabled]"
      echo "  --exclude <glob>       Skip scripts matching the glob (basename match)"
      echo "  --no-skip-disabled     Do not auto-skip files with disabled suffixes"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# Find all .sh scripts under the phase-0 directory, sort them in
# version-like order (so 00-.. runs before 01-.. and subfolders are respected)
mapfile -t SCRIPTS < <(find "$PHASE0_DIR" -type f -name "*.sh" -print | sort -V)

if [ ${#SCRIPTS[@]} -eq 0 ]; then
  echo "No .sh scripts found in $PHASE0_DIR"
  exit 0
fi

for script in "${SCRIPTS[@]}"; do
  [ -f "$script" ] || continue

  name="$(basename "$script")"

  # Skip disabled-style filenames unless disabled skipping is turned off
  if [ "$SKIP_DISABLED" = true ]; then
    case "$name" in
      *.disabled.sh|*.sh.disabled|DISABLED_*|*_disabled.sh)
        echo
        echo "------------------------------------------------------------"
        echo "Skipping disabled script: $script"
        echo "------------------------------------------------------------"
        continue
        ;;
    esac
  fi

  # Check user-supplied exclude globs against the basename
  skip=false
  for pat in "${EXCLUDES[@]}"; do
    if [[ "$name" == $pat ]]; then
      skip=true
      break
    fi
  done
  if [ "$skip" = true ]; then
    echo
    echo "------------------------------------------------------------"
    echo "Excluded by pattern, skipping: $script"
    echo "------------------------------------------------------------"
    continue
  fi

  echo
  echo "------------------------------------------------------------"
  echo "Running: $script"
  echo "------------------------------------------------------------"

  # Execute with bash to avoid needing executable bit and to provide a clean shell
  if bash "$script"; then
    echo "✅ Completed: $name"
  else
    echo "❌ Failed: $name"
    exit 1
  fi
done

echo
echo "🎉 All phase 0 scripts executed successfully."
