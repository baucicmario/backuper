#!/usr/bin/env bash
# tests/test_run_orchestrator.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/assert.sh"

TEST_TMP="$SCRIPT_DIR/tmp_test_orchestrator"
mkdir -p "$TEST_TMP"

ORCHESTRATOR_SCRIPT="$(realpath "$SCRIPT_DIR/../modules/backup/run.sh")"

# Mock dockge stacks directory
STACKS_DIR="$TEST_TMP/stacks"
mkdir -p "$STACKS_DIR/stack1"

cat > "$STACKS_DIR/stack1/compose.yaml" <<'EOF'
services:
  app:
    image: alpine
    volumes:
      - ./data:/app/data
EOF
echo "ENV_VAR=1" > "$STACKS_DIR/stack1/.env"
mkdir -p "$STACKS_DIR/stack1/data"
echo "hello test" > "$STACKS_DIR/stack1/data/test.txt"

# Run orchestrator
OUTPUT_DIR="$TEST_TMP/backup_out"

bash "$ORCHESTRATOR_SCRIPT" \
  --stacks-dir "$STACKS_DIR" \
  --output "$OUTPUT_DIR" \
  --select-all \
  --copy-all > "$TEST_TMP/run.log" 2>&1

# Verify expected outputs
ARCHIVE_PATH="$OUTPUT_DIR/stack1__app.tar.gz"
if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "Failed! Archive not found at $ARCHIVE_PATH"
  cat "$TEST_TMP/run.log"
  exit 1
fi

assert_match "\[job-phase: discover\]" "$(cat "$TEST_TMP/run.log")" "Log should contain phase markers"
assert_match "\[job-phase: archive\]" "$(cat "$TEST_TMP/run.log")" "Log should contain archive phase"

rm -rf "$TEST_TMP"
echo "test_run_orchestrator.sh passed"
