#!/usr/bin/env bash
# tests/test_tar_transform.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/assert.sh"

TEST_TMP="$SCRIPT_DIR/tmp_test_transform"
mkdir -p "$TEST_TMP"

ARCHIVE_SCRIPT="$(realpath "$SCRIPT_DIR/../modules/backup/steps/09-archive-service.sh")"

# Setup mock service
SERVICE_NAME="mock_service"
SERVICE_DIR="$TEST_TMP/$SERVICE_NAME"
mkdir -p "$SERVICE_DIR"
echo "compose content" > "$SERVICE_DIR/docker-compose.yml"

# Setup mock host mount
HOST_MOUNT_DIR="$TEST_TMP/host_data"
mkdir -p "$HOST_MOUNT_DIR"
echo "secret data" > "$HOST_MOUNT_DIR/data.txt"

# Create .backup-mounts file
# format: host_path|dest_name
echo "$(realpath "$HOST_MOUNT_DIR")|data_mount" > "$SERVICE_DIR/.backup-mounts"

# Run archive script
bash "$ARCHIVE_SCRIPT" "$SERVICE_DIR" > /dev/null

ARCHIVE_PATH="$TEST_TMP/${SERVICE_NAME}.tar.gz"
if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "Failed! Archive was not created at $ARCHIVE_PATH"
  exit 1
fi

# Extract and verify
EXTRACT_DIR="$TEST_TMP/extracted"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"

assert_eq "compose content" "$(cat "$EXTRACT_DIR/$SERVICE_NAME/docker-compose.yml")" "Metadata should be archived"
assert_eq "secret data" "$(cat "$EXTRACT_DIR/$SERVICE_NAME/data_mount/data.txt")" "Host data should be archived and transformed correctly"

# The host data should NOT be duplicated into the SERVICE_DIR (since we bypassed 08-copy-dir.sh in reality, 
# but here we just manually wrote .backup-mounts)
if [[ -d "$SERVICE_DIR/data_mount" ]]; then
  echo "Failed! The data_mount should not exist in the staging directory."
  exit 1
fi

rm -rf "$TEST_TMP"
echo "test_tar_transform.sh passed"
