#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

T="$SCRIPT_DIR/tasks"

DOCKGE_STACKS_DIR="${DOCKGE_STACKS_DIR:-/opt/stacks}"
OUTPUT_DIR="${CENTRAL_BACKUP_DIR:+$CENTRAL_BACKUP_DIR/split_stacks}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/split_stacks}"
DRY_RUN=false
FORCE=false
MOUNT_MODE=prompt   # prompt | copy-all | reject-all

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stacks-dir)  shift; DOCKGE_STACKS_DIR="$1" ;;
    --output)      shift; OUTPUT_DIR="$1" ;;
    --dry-run)     DRY_RUN=true ;;
    --force)       FORCE=true ;;
    --copy-all)    MOUNT_MODE=copy-all ;;
    --reject-all)  MOUNT_MODE=reject-all ;;
    *) die "Unknown flag: $1" ;;
  esac
  shift
done

mkdir -p "$OUTPUT_DIR"
SERVICE_DIRS=()

# STEP 1 — Find every valid Dockge stack folder
mapfile -t STACK_DIRS < <(bash "$T/01-discover-stacks.sh" "$DOCKGE_STACKS_DIR")

# STEP 2 — For each stack: extract every service
for stack_dir in "${STACK_DIRS[@]}"; do
  compose_file="$stack_dir/compose.yaml"
  env_file="$stack_dir/.env"

  mapfile -t SERVICES < <(bash "$T/02-extract-services.sh" "$compose_file")

  for service in "${SERVICES[@]}"; do
    out_dir="$OUTPUT_DIR/$(bash "$T/03-create-service-compose.sh" "$compose_file" "$service" "$OUTPUT_DIR" "$DRY_RUN" "$FORCE")"
    bash "$T/04-extract-env.sh"    "$out_dir" "$env_file"
    bash "$T/05-write-metadata.sh" "$out_dir" "$stack_dir" "$service"
    bash "$T/07-write-restore.sh"  "$out_dir" "$DOCKGE_STACKS_DIR"
    SERVICE_DIRS+=("$out_dir")
  done
done

# STEP 3 — Copy bind-mounted data into each service folder
for service_dir in "${SERVICE_DIRS[@]}"; do
  bash "$T/06-copy-bind-mounts.sh" "$service_dir" "$MOUNT_MODE"
done

# STEP 4 — Summary
ok "Phase 1 complete — ${#SERVICE_DIRS[@]} service(s) backed up to $OUTPUT_DIR"