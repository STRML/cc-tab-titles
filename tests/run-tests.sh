#!/bin/bash
# Run all tests in this directory.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

FAILED=0
for t in "$HERE"/test-*.sh; do
  [ -f "$t" ] || continue
  echo "==> $(basename "$t")"
  if ! bash "$t"; then
    FAILED=$((FAILED + 1))
  fi
  echo
done

if [ "$FAILED" -gt 0 ]; then
  echo "FAILED: $FAILED test file(s)"
  exit 1
fi
echo "All test files passed."
