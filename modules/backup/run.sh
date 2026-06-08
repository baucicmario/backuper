#!/usr/bin/env bash
# phase-1/orchestrator.sh — Main Phase 1 orchestrator
# Coordinates the discovery of Dockge stacks and extraction of services.
# Runs tasks in sequence: discover stacks → extract services → backup configs → copy data
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

# Shorthand for tasks directory
S="$SCRIPT_DIR/steps"

# ── Configuration with sensible defaults ──────────────────────
# Source stacks directory (where Dockge stores stack configs)
DOCKGE_STACKS_DIR="${DOCKGE_STACKS_DIR:-/opt/stacks}"
# Destination for extracted services
OUTPUT_DIR="${CENTRAL_BACKUP_DIR:+$CENTRAL_BACKUP_DIR/split_stacks}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/split_stacks}"
# Flags for operation modes
DRY_RUN=false  # Don't actually perform actions if true
FORCE=false  # Overwrite existing backups if true
MOUNT_MODE=prompt   # How to handle bind mounts: prompt | copy-all | reject-all

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

# Create output directory
mkdir -p "$OUTPUT_DIR"
SERVICE_DIRS=()  # Track all extracted service directories

# ────────────────────────────────────────────────────────────────────────────
# STEP 1 — Discover all Dockge stacks
# ────────────────────────────────────────────────────────────────────────────
mapfile -t STACK_DIRS < <(bash "$S/01-discover-stacks.sh" "$DOCKGE_STACKS_DIR")

# ────────────────────────────────────────────────────────────────────────────
# STEP 2 — Extract services from each stack
# ────────────────────────────────────────────────────────────────────────────
for stack_dir in "${STACK_DIRS[@]}"; do
  compose_file="$stack_dir/compose.yaml"
  env_file="$stack_dir/.env"

  mapfile -t SERVICES < <(bash "$S/02-extract-services.sh" "$compose_file")

  for service in "${SERVICES[@]}"; do
    # Create isolated service folder with its docker-compose.yml
    out_dir="$OUTPUT_DIR/$(bash "$S/03-create-service-compose.sh" "$compose_file" "$service" "$OUTPUT_DIR" "$DRY_RUN" "$FORCE")"
    # Extract filtered .env variables used by this service
    bash "$S/04-extract-env.sh"    "$out_dir" "$env_file"
    # Write metadata about where this service came from
    bash "$S/05-write-metadata.sh" "$out_dir" "$stack_dir" "$service"
    # Generate a restore.sh script to merge this service back
    bash "$S/07-write-restore.sh"  "$out_dir" "$DOCKGE_STACKS_DIR"
    SERVICE_DIRS+=("$out_dir")  # Track for next phase
  done
done

# ────────────────────────────────────────────────────────────────────────────
# STEP 3 — Copy bind-mounted data into each service folder
# ────────────────────────────────────────────────────────────────────────────
for service_dir in "${SERVICE_DIRS[@]}"; do
  bash "$S/06-copy-bind-mounts.sh" "$service_dir" "$MOUNT_MODE"
done

# ────────────────────────────────────────────────────────────────────────────
# STEP 4 — Done
# ────────────────────────────────────────────────────────────────────────────
ok "Phase 1 complete — ${#SERVICE_DIRS[@]} service(s) backed up to $OUTPUT_DIR"