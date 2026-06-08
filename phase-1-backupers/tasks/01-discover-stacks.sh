#!/usr/bin/env bash
# tasks/01-discover-stacks.sh
# Scan STACKS_DIR and print the path of every folder that contains a compose.yaml.
# Output: one absolute path per line (stdout).
# Usage: 01-discover-stacks.sh <stacks_dir>
set -euo pipefail

STACKS_DIR="${1:-${DOCKGE_STACKS_DIR:-/opt/stacks}}"

[[ -d "$STACKS_DIR" ]] || { echo "Error: stacks dir not found: $STACKS_DIR" >&2; exit 1; }

while IFS= read -r -d '' stack_dir; do
  if [[ -f "$stack_dir/compose.yaml" ]]; then
    echo "$stack_dir"
  fi
done < <(find "$STACKS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)