#!/bin/bash
# Integration test: in cmux, a `/rename` (custom-title in the transcript) makes
# the Stop hook clear cc-tab-titles' tab override and defer to cmux's native
# name — it must NOT set a competing title and must suppress the Haiku path.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/assert.sh"

echo "test-rename-cmux.sh"

SCRIPT="$HERE/../hooks/set-tab-title.sh"

TEST_TMP_ROOT="${CCTT_TEST_TMP:-/private/tmp/claude}"
mkdir -p "$TEST_TMP_ROOT" 2>/dev/null
SANDBOX="$TEST_TMP_ROOT/cctt-rename-$$-$RANDOM"
mkdir -p "$SANDBOX/state" "$SANDBOX/bin" "$SANDBOX/lib" || { echo "cannot create sandbox"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT

# Patched copy of the hook with an isolated TITLE_DIR + lib alongside it
PATCHED="$SANDBOX/set-tab-title.sh"
sed "s|^TITLE_DIR=.*|TITLE_DIR=$SANDBOX/state|" "$SCRIPT" > "$PATCHED"
chmod +x "$PATCHED"
cp "$HERE/../hooks/lib/"*.sh "$SANDBOX/lib/"

# Stub `cmux` that records every invocation's args
CMUX_LOG="$SANDBOX/cmux.log"
cat > "$SANDBOX/bin/cmux" <<EOF
#!/bin/bash
echo "\$*" >> "$CMUX_LOG"
exit 0
EOF
chmod +x "$SANDBOX/bin/cmux"
export PATH="$SANDBOX/bin:$PATH"
export CMUX_SURFACE_ID="rename-test-surface"

SESSION="rename-sess"
TRANSCRIPT="$SANDBOX/t.jsonl"
printf '%s\n' \
  '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"do work"}]}}' \
  '{"type":"ai-title","aiTitle":"Auto title NOT to use","sessionId":"rename-sess"}' \
  '{"type":"custom-title","customTitle":"foobar","sessionId":"rename-sess"}' \
  > "$TRANSCRIPT"
PAYLOAD='{"session_id":"'"$SESSION"'","transcript_path":"'"$TRANSCRIPT"'"}'

# First run: should clear-name and defer
RC=$(echo "$PAYLOAD" | "$PATCHED" >/dev/null 2>&1; echo $?)
assert_eq "0" "$RC" "set-tab-title.sh exits 0 on /rename in cmux"

CMUX_CALLS=$(cat "$CMUX_LOG" 2>/dev/null)
assert_contains "$CMUX_CALLS" "clear-name" "cmux override is cleared (tab-action clear-name)"
case "$CMUX_CALLS" in
  *"rename-tab"*) _fail "does NOT set a competing title via rename-tab" "got: $CMUX_CALLS" ;;
  *)              _pass "does NOT set a competing title via rename-tab" ;;
esac

assert_file_exists "$SANDBOX/state/$SESSION.rename" "rename marker written"
assert_eq "foobar" "$(cat "$SANDBOX/state/$SESSION.rename")" "rename marker holds the custom title"

if [ -f "$SANDBOX/state/$SESSION.uhash" ]; then
  _fail "Haiku path suppressed (no .uhash written)" "uhash present"
else
  _pass "Haiku path suppressed (no .uhash written)"
fi

# Second run with the same rename: must NOT clear-name again (idempotent)
: > "$CMUX_LOG"
echo "$PAYLOAD" | "$PATCHED" >/dev/null 2>&1
SECOND=$(cat "$CMUX_LOG" 2>/dev/null)
case "$SECOND" in
  *"clear-name"*) _fail "idempotent: no repeat clear-name when rename unchanged" "got: $SECOND" ;;
  *)              _pass "idempotent: no repeat clear-name when rename unchanged" ;;
esac

# A new rename value triggers clear-name again
: > "$CMUX_LOG"
printf '%s\n' '{"type":"custom-title","customTitle":"different name","sessionId":"rename-sess"}' >> "$TRANSCRIPT"
echo "$PAYLOAD" | "$PATCHED" >/dev/null 2>&1
THIRD=$(cat "$CMUX_LOG" 2>/dev/null)
assert_contains "$THIRD" "clear-name" "a new /rename value re-clears the override"
assert_eq "different name" "$(cat "$SANDBOX/state/$SESSION.rename")" "marker updates to the new rename"

print_summary
