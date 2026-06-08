#!/usr/bin/env bash
# tasks/05-write-metadata.sh
# Write a .stack-meta provenance file into the service output folder.
# Usage: 05-write-metadata.sh <out_dir> <stack_dir> <service>
set -euo pipefail

OUT_DIR="${1:?Usage: $0 <out_dir> <stack_dir> <service>}"
STACK_DIR="${2:?}"
SERVICE="${3:?}"

compose_file="$STACK_DIR/compose.yaml"
env_file="$STACK_DIR/.env"

source_compose_abs="$(realpath "$compose_file" 2>/dev/null || echo "$compose_file")"
source_env_abs=""
[[ -f "$env_file" ]] && source_env_abs="$(realpath "$env_file" 2>/dev/null || echo "$env_file")"

cat > "$OUT_DIR/.stack-meta" <<META
SOURCE_STACK=$(basename "$STACK_DIR")
SOURCE_FILE=${source_compose_abs}
SOURCE_ENV=${source_env_abs}
SERVICE_NAME=${SERVICE}
EXTRACTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
META