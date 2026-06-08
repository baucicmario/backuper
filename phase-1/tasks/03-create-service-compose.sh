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
# Networks can be a list (- media_network) or a map (media_network: {...})
# List style: yq returns numeric indexes for keys, values are the network names
# Map style:  yq returns network names as keys
svc_networks_raw="$(yq ".services.\"${SERVICE}\".networks" "$COMPOSE_FILE" 2>/dev/null || true)"

if [[ -n "$svc_networks_raw" && "$svc_networks_raw" != "null" ]]; then
  # Detect list vs map: if it's a sequence, extract values; if map, extract keys
  is_seq="$(yq ".services.\"${SERVICE}\".networks | type" "$COMPOSE_FILE" 2>/dev/null || true)"

  if [[ "$is_seq" == "!!seq" ]]; then
    # List style: - media_network
    mapfile -t net_names < <(yq ".services.\"${SERVICE}\".networks[]" "$COMPOSE_FILE" 2>/dev/null || true)
  else
    # Map style: media_network: null or media_network: {aliases: [...]}
    mapfile -t net_names < <(yq ".services.\"${SERVICE}\".networks | keys | .[]" "$COMPOSE_FILE" 2>/dev/null || true)
  fi

  for net in "${net_names[@]}"; do
    [[ -z "$net" || "$net" == "null" ]] && continue
    net_def="$(yq ".networks.\"${net}\"" "$COMPOSE_FILE" 2>/dev/null || true)"
    if [[ -n "$net_def" && "$net_def" != "null" ]]; then
      yq -i ".networks.\"${net}\" = load(\"${COMPOSE_FILE}\").networks.\"${net}\"" "$out_compose"
    else
      yq -i ".networks.\"${net}\".driver = \"bridge\"" "$out_compose"
    fi
  done
fi

# ── Referenced named volumes (skip bind mounts) ───────────────────────────────
svc_volumes_raw="$(yq ".services.\"${SERVICE}\".volumes[]" "$COMPOSE_FILE" 2>/dev/null || true)"
if [[ -n "$svc_volumes_raw" ]]; then
  while IFS= read -r vol_entry; do
    [[ -z "$vol_entry" || "$vol_entry" == "null" ]] && continue
    vol_src="$(printf '%s' "$vol_entry" | cut -d: -f1)"
    [[ "$vol_src" =~ ^[/\.~\$] ]] && continue
    vol_def="$(yq ".volumes.\"${vol_src}\"" "$COMPOSE_FILE" 2>/dev/null || true)"
    if [[ -n "$vol_def" && "$vol_def" != "null" ]]; then
      yq -i ".volumes.\"${vol_src}\" = load(\"${COMPOSE_FILE}\").volumes.\"${vol_src}\"" "$out_compose"
    else
      yq -i ".volumes.\"${vol_src}\" = null" "$out_compose"
    fi
  done <<< "$svc_volumes_raw"
fi

# ── Strip empty/null top-level blocks (volumes only — networks always get a definition now) ──
yq -i 'del(.volumes | select(. == {} or . == null))' "$out_compose" 2>/dev/null || true

# Print folder name to the real stdout (fd3) so the orchestrator can capture it
echo "$folder_name" >&3