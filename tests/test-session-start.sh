#!/bin/bash
# Integration test: pipe mock JSON to session-start.sh in an isolated TITLE_DIR
# and verify the title and ownership files are written correctly.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/assert.sh"

echo "test-session-start.sh"

SCRIPT="$HERE/../hooks/session-start.sh"
[ -x "$SCRIPT" ] || chmod +x "$SCRIPT"

# Isolate state under a writable dir so we don't touch /tmp/claude-tab-titles
TEST_TMP_ROOT="${CCTT_TEST_TMP:-/private/tmp/claude}"
mkdir -p "$TEST_TMP_ROOT" 2>/dev/null
SANDBOX="$TEST_TMP_ROOT/cctt-test-$$-$RANDOM"
mkdir -p "$SANDBOX" || { echo "cannot create test sandbox dir: $SANDBOX"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT

# session-start.sh hardcodes TITLE_DIR=/tmp/claude-tab-titles. We can't override
# without editing the script, so we run a copy with the path patched.
PATCHED="$SANDBOX/session-start.sh"
sed "s|^TITLE_DIR=.*|TITLE_DIR=$SANDBOX/state|" "$SCRIPT" > "$PATCHED"
chmod +x "$PATCHED"

# Force a known TAB_KEY since /dev/tty isn't available in non-tty test runs
export CMUX_SURFACE_ID="test-surface-1"

SESSION="01H-TEST-SESSION-ID"
PAYLOAD='{"session_id":"'"$SESSION"'","cwd":"'"$PWD"'"}'

OUT=$(echo "$PAYLOAD" | "$PATCHED" 2>&1)
RC=$?

assert_eq "0" "$RC" "session-start.sh exits 0"

TITLE_FILE="$SANDBOX/state/$SESSION"
assert_file_exists "$TITLE_FILE" "title file written for session"

# Title should be the project folder name (basename of git toplevel)
EXPECTED_NAME=$(cd "$HERE/.." && basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
EXPECTED_TITLE=$(echo "$EXPECTED_NAME" | cut -c1-30)
ACTUAL_TITLE=$(cat "$TITLE_FILE")
assert_eq "$EXPECTED_TITLE" "$ACTUAL_TITLE" "title equals project folder basename (truncated to 30)"

# Title must not start with [ — old "[slug] new session" format is gone
case "$ACTUAL_TITLE" in
  '['*) _fail "title no longer wrapped in [brackets]" "got '$ACTUAL_TITLE'" ;;
  *)    _pass "title no longer wrapped in [brackets]" ;;
esac

# Owner file written for cmux tab
OWNER_FILE="$SANDBOX/state/owner-cmux-test-surface-1"
assert_file_exists "$OWNER_FILE" "owner file written for tab"
assert_eq "$SESSION" "$(cat "$OWNER_FILE")" "owner file contains session id"

# Pinned file from prior session is cleared
mkdir -p "$SANDBOX/state"
touch "$SANDBOX/state/$SESSION.pinned"
echo "$PAYLOAD" | "$PATCHED" >/dev/null 2>&1
if [ ! -f "$SANDBOX/state/$SESSION.pinned" ]; then
  _pass "pinned file cleared on session start"
else
  _fail "pinned file cleared on session start" "still present"
fi

# Empty/missing session id => exit 0 without writing
echo '{"foo":"bar"}' | "$PATCHED" >/dev/null 2>&1
assert_eq "0" "$?" "exits 0 when payload has no session_id"

print_summary
