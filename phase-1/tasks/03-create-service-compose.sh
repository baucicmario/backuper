#!/usr/bin/env bash
# tasks/03-create-service-compose.sh
set -euo pipefail

exec 3>&1
exec 1>&2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_cmd yq
require_cmd realpath

COMPOSE_FILE="${1:?Usage: $0 <compose_file> <service> <output_dir> <dry_run> <force>}"
SERVICE="${2:?}"
OUTPUT_DIR="${3:?}"
DRY_RUN="${4:-false}"
FORCE="${5:-false}"

stack_name="$(basename "$(dirname "$COMPOSE_FILE")")"
safe_service="$(sanitize_dirname "$SERVICE")"
folder_name="${stack_name}__${safe_service}"
out_dir="$OUTPUT_DIR/$folder_name"

if [[ -d "$out_dir" ]]; then
  if [[ "$FORCE" == false ]]; then
    warn "Output folder already exists, skipping: $out_dir"
    echo "$folder_name" >&3
    exit 0
  fi
  warn "Overwriting existing folder (--force): $out_dir"
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "$folder_name" >&3
  exit 0
fi

mkdir -p "$out_dir"
out_compose="$out_dir/docker-compose.yml"

# ── Service definition ────────────────────────────────────────────────────────
yq -n ".services.\"${SERVICE}\" = load(\"${COMPOSE_FILE}\").services.\"${SERVICE}\"" \
  > "$out_compose"

# ── Referenced networks ───────────────────────────────────────────────────────
svc_networks="$(yq ".services.\"${SERVICE}\".networks | keys | .[]" "$COMPOSE_FILE" 2>/dev/null || true)"
if [[ -n "$svc_networks" ]]; then
  while IFS= read -r net; do
    [[ -z "$net" || "$net" == "null" ]] && continue
    [[ "$net" =~ ^[0-9]+$ ]] && continue
    net_def="$(yq ".networks.\"${net}\"" "$COMPOSE_FILE" 2>/dev/null || true)"
    if [[ -n "$net_def" && "$net_def" != "null" ]]; then
      yq -i ".networks.\"${net}\" = load(\"${COMPOSE_FILE}\").networks.\"${net}\"" "$out_compose"
    else
      yq -i ".networks.\"${net}\" = null" "$out_compose"
    fi
  done <<< "$svc_networks"
fi

# ── Referenced named volumes (skip bind mounts) ───────────────────────────────
# Strategy: skip anything whose source starts with / . ~ or $ (env var = bind mount path)
# No eval needed — just string pattern matching on the raw value
svc_volumes_raw="$(yq ".services.\"${SERVICE}\".volumes[]" "$COMPOSE_FILE" 2>/dev/null || true)"
if [[ -n "$svc_volumes_raw" ]]; then
  while IFS= read -r vol_entry; do
    [[ -z "$vol_entry" || "$vol_entry" == "null" ]] && continue
    vol_src="$(printf '%s' "$vol_entry" | cut -d: -f1)"
    # Skip bind mounts: absolute paths, relative paths, tilde, or env var references
    [[ "$vol_src" =~ ^[/\.~\$] ]] && continue
    # What's left is a true named volume (e.g. "app_data", "db_vol")
    vol_def="$(yq ".volumes.\"${vol_src}\"" "$COMPOSE_FILE" 2>/dev/null || true)"
    if [[ -n "$vol_def" && "$vol_def" != "null" ]]; then
      yq -i ".volumes.\"${vol_src}\" = load(\"${COMPOSE_FILE}\").volumes.\"${vol_src}\"" "$out_compose"
    else
      yq -i ".volumes.\"${vol_src}\" = null" "$out_compose"
    fi
  done <<< "$svc_volumes_raw"
fi

# Print folder name to the real stdout (fd3) so the orchestrator can capture it
echo "$folder_name" >&3