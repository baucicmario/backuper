#!/usr/bin/env bash

set -e

# --- Configuration Variables ---
COMPOSE_FILE="./docker-compose.yml"
ENV_FILE="./.env"

# --------------------------------
# 1. Validation
# --------------------------------
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "Error: Docker Compose file not found at $COMPOSE_FILE"
    exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
    echo "Warning: .env file not found at $ENV_FILE. Proceeding without env resolution."
else
    echo "Loading environment variables from $ENV_FILE..."
    export $(grep -v '^#' "$ENV_FILE" | xargs)
fi

# Verify yq is installed and working
if ! command -v yq &> /dev/null; then
    echo "Error: 'yq' is not installed or not in your PATH."
    echo "Please run your global installer script to set it up."
    exit 1
fi

COMPOSE_DIR=$(dirname "$(realpath "$COMPOSE_FILE")")
echo "Target destination folder: $COMPOSE_DIR"
echo "------------------------------------------------"

# --------------------------------
# 2. Parse and Process Volumes
# --------------------------------
echo "Scanning for volumes..."

# Use yq to extract volumes, then pipe to the processor
yq '.services.*.volumes[]' "$COMPOSE_FILE" 2>/dev/null | while read -r raw_volume; do
    [ -z "$raw_volume" ] && continue

    # Resolve environment variables (like ${CONTAINERS_ROOT})
    expanded_volume=$(eval echo "$raw_volume")

    # Split host and container mappings
    host_path=$(echo "$expanded_volume" | cut -d':' -f1)
    container_path=$(echo "$expanded_volume" | cut -d':' -f2)

    # Bypass named or anonymous volumes
    if [[ ! "$host_path" =~ ^[/\.] ]] && [[ ! "$host_path" =~ ^~ ]]; then
        echo "Skipping named/anonymous volume: $expanded_volume"
        continue
    fi

    # Expand tilde (~) if it exists
    eval host_path="$host_path"

    # Ensure source directory exists
    if [ ! -d "$host_path" ]; then
        echo "Skipping: Source directory '$host_path' does not exist."
        continue
    fi

    # Extract destination folder name from container path
    dest_folder_name=$(basename "$container_path")
    destination_path="$COMPOSE_DIR/$dest_folder_name"

    # Avoid self-copying
    if [ "$(realpath "$host_path")" = "$(realpath "$destination_path" 2>/dev/null)" ]; then
        echo "Skipping: '$host_path' is already the destination folder."
        continue
    fi

    # --------------------------------
    # 3. Execution (Copying)
    # --------------------------------
    echo "Processing: $host_path -> $destination_path"
    mkdir -p "$destination_path"

    if cp -a "$host_path/." "$destination_path/"; then
        echo "Successfully copied contents to $destination_path"
    else
        echo "Failed to copy $host_path"
    fi
    echo "---"

done

echo "Process complete!"