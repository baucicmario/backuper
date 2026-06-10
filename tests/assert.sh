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
