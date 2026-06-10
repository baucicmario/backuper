#!/usr/bin/env bash
# tests/test_09_archive_pipeline.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/assert.sh"

TEST_TMP="$SCRIPT_DIR/tmp_test_pipeline"
mkdir -p "$TEST_TMP/bin"
export PATH="$TEST_TMP/bin:$PATH"

SERVICE_DIR="$TEST_TMP/mock_service"
mkdir -p "$SERVICE_DIR"
echo "test data" > "$SERVICE_DIR/docker-compose.yml"

ARCHIVE_SCRIPT="$(realpath "$SCRIPT_DIR/../modules/backup/steps/09-archive-service.sh")"

setup_mock_tar() {
  local exit_code="$1"
  local stderr_msg="${2:-}"
  cat > "$TEST_TMP/bin/tar" <<EOF
#!/usr/bin/env bash
if [[ "$stderr_msg" != "" ]]; then
  echo "$stderr_msg" >&2
fi
exit $exit_code
EOF
  chmod +x "$TEST_TMP/bin/tar"
}

setup_mock_pv() {
  cat > "$TEST_TMP/bin/pv" <<'EOF'
#!/usr/bin/env bash
# just pass through
cat
EOF
  chmod +x "$TEST_TMP/bin/pv"
}

setup_mock_pv

# ── Scenario A: tar exits 1 (file changed) ──
setup_mock_tar 1 "tar: Removing leading /"
echo "Testing: tar exits 1 (should be ignored)"
bash "$ARCHIVE_SCRIPT" "$SERVICE_DIR" > "$TEST_TMP/out_A" 2> "$TEST_TMP/err_A" || true
if ! grep -q "Archived" "$TEST_TMP/out_A"; then
  echo "Failed! Script should have succeeded despite tar exit 1."
  cat "$TEST_TMP/out_A"
  cat "$TEST_TMP/err_A"
  exit 1
fi
assert_match "Archived" "$(cat "$TEST_TMP/out_A")" "Output should indicate success"


# ── Scenario B: tar exits 2 (fatal error) ──
setup_mock_tar 2 "tar: fatal error"
echo "Testing: tar exits 2 (should fail pipeline)"
if bash "$ARCHIVE_SCRIPT" "$SERVICE_DIR" > "$TEST_TMP/out_B" 2> "$TEST_TMP/err_B"; then
  echo "Failed! Script should have failed on tar exit 2."
  exit 1
fi
assert_match "tar failed for" "$(cat "$TEST_TMP/err_B")" "Output should show tar failure message"


# ── Scenario C: Swallowed Error Test ──
# To test this, we mock gzip to print an error and fail
cat > "$TEST_TMP/bin/gzip" <<'EOF'
#!/usr/bin/env bash
echo "gzip: No space left on device" >&2
exit 1
EOF
chmod +x "$TEST_TMP/bin/gzip"
setup_mock_tar 0 ""

echo "Testing: stderr passthrough for errors"
if bash "$ARCHIVE_SCRIPT" "$SERVICE_DIR" > "$TEST_TMP/out_C" 2> "$TEST_TMP/err_C"; then
  echo "Failed! Script should have failed due to gzip error."
  exit 1
fi

err_out="$(cat "$TEST_TMP/err_C")"
# It should contain the literal gzip error, NOT [pv: gzip:]
assert_match "gzip: No space left on device" "$err_out" "Gzip error should be passed through unmodified"
if [[ "$err_out" =~ \[pv:\ gzip:\] ]]; then
  echo "Failed! awk swallowed the gzip error and formatted it as pv output."
  exit 1
fi

rm -f "$TEST_TMP/bin/gzip"
rm -rf "$TEST_TMP"
echo "test_09_archive_pipeline.sh passed"
