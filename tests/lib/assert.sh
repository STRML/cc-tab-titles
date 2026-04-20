#!/bin/bash
# Tiny test helpers. Source this in test files.
# Usage:
#   assert_eq "expected" "actual" "description"
#   assert_contains "haystack" "needle" "description"
#   assert_file_contains "path" "needle" "description"

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_FAILURES=()

_pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  printf '  \033[32mPASS\033[0m %s\n' "$1"
}

_fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  TESTS_FAILURES+=("$1")
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  [ -n "$2" ] && printf '       %s\n' "$2"
}

assert_eq() {
  local expected="$1" actual="$2" desc="$3"
  if [ "$expected" = "$actual" ]; then
    _pass "$desc"
  else
    _fail "$desc" "expected='$expected' actual='$actual'"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" desc="$3"
  case "$haystack" in
    *"$needle"*) _pass "$desc" ;;
    *) _fail "$desc" "needle='$needle' not found in '$haystack'" ;;
  esac
}

assert_file_contains() {
  local path="$1" needle="$2" desc="$3"
  if [ ! -f "$path" ]; then
    _fail "$desc" "file not found: $path"
    return
  fi
  if grep -qF "$needle" "$path"; then
    _pass "$desc"
  else
    _fail "$desc" "needle='$needle' not in $path"
  fi
}

assert_file_exists() {
  local path="$1" desc="$2"
  if [ -f "$path" ]; then
    _pass "$desc"
  else
    _fail "$desc" "file does not exist: $path"
  fi
}

assert_le() {
  local a="$1" b="$2" desc="$3"
  if [ "$a" -le "$b" ]; then
    _pass "$desc"
  else
    _fail "$desc" "expected $a <= $b"
  fi
}

print_summary() {
  echo
  echo "----------------------------------------"
  echo "Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
  if [ "$TESTS_FAILED" -gt 0 ]; then
    echo "Failures:"
    for f in "${TESTS_FAILURES[@]}"; do
      echo "  - $f"
    done
    exit 1
  fi
  exit 0
}
