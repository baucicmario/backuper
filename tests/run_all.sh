#!/usr/bin/env bash
# tests/run_all.sh
# Discovers and runs all test scripts in the tests/ directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Print colored text
green() { echo -e "\033[32m$*\033[0m"; }
red()   { echo -e "\033[31m$*\033[0m"; }
blue()  { echo -e "\033[34m$*\033[0m"; }
bold()  { echo -e "\033[1m$*\033[0m"; }

# Basic test assertion library
export ASSERT_SCRIPT="$SCRIPT_DIR/assert.sh"
cat > "$ASSERT_SCRIPT" << 'EOF'
#!/usr/bin/env bash
assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-}"
  if [[ "$expected" != "$actual" ]]; then
    echo -e "\033[31mAssertion failed!\033[0m"
    [[ -n "$msg" ]] && echo "Message: $msg"
    echo "Expected: $expected"
    echo "Actual  : $actual"
    exit 1
  fi
}
assert_match() {
  local regex="$1"
  local actual="$2"
  local msg="${3:-}"
  if [[ ! "$actual" =~ $regex ]]; then
    echo -e "\033[31mAssertion failed!\033[0m"
    [[ -n "$msg" ]] && echo "Message: $msg"
    echo "Regex : $regex"
    echo "Actual: $actual"
    exit 1
  fi
}
export -f assert_eq assert_match
EOF
chmod +x "$ASSERT_SCRIPT"

passed=0
failed=0

echo "Running tests..."
for test_script in test_*.sh; do
  if [[ -f "$test_script" ]]; then
    bold "\n▶ Running $test_script"
    if bash "$test_script"; then
      green "✔ $test_script passed"
      (( passed++ )) || true
    else
      red "❌ $test_script failed"
      (( failed++ )) || true
    fi
  fi
done

bold "\nTest Summary"
if [[ $failed -gt 0 ]]; then
  red "$failed test(s) failed."
  green "$passed test(s) passed."
  exit 1
else
  green "All $passed test(s) passed!"
  exit 0
fi
