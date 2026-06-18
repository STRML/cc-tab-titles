#!/bin/bash
# Unit test: last_custom_title() extracts the user's `/rename` title from a
# transcript, ignores auto-generated "ai-title" entries, and returns the most
# recent rename when several are present.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/../hooks/lib/session-title.sh"

echo "test-session-title.sh"

TEST_TMP_ROOT="${CCTT_TEST_TMP:-/private/tmp/claude}"
mkdir -p "$TEST_TMP_ROOT" 2>/dev/null
SANDBOX="$TEST_TMP_ROOT/cctt-title-$$-$RANDOM"
mkdir -p "$SANDBOX" || { echo "cannot create sandbox: $SANDBOX"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT

# No custom-title anywhere => empty
T1="$SANDBOX/t1.jsonl"
printf '%s\n' \
  '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}' \
  '{"type":"ai-title","aiTitle":"Auto generated thing","sessionId":"s"}' \
  > "$T1"
assert_eq "" "$(last_custom_title "$T1")" "ai-title entries are ignored (no rename => empty)"

# A single /rename
T2="$SANDBOX/t2.jsonl"
printf '%s\n' \
  '{"type":"ai-title","aiTitle":"Auto thing","sessionId":"s"}' \
  '{"type":"custom-title","customTitle":"deploy pipeline","sessionId":"s"}' \
  > "$T2"
assert_eq "deploy pipeline" "$(last_custom_title "$T2")" "single custom-title extracted"

# Multiple renames => most recent wins, even with ai-title interleaved
T3="$SANDBOX/t3.jsonl"
printf '%s\n' \
  '{"type":"custom-title","customTitle":"first name","sessionId":"s"}' \
  '{"type":"ai-title","aiTitle":"Auto thing","sessionId":"s"}' \
  '{"type":"custom-title","customTitle":"second name","sessionId":"s"}' \
  > "$T3"
assert_eq "second name" "$(last_custom_title "$T3")" "latest custom-title wins over earlier ones"

# Titles with special characters survive (quotes, spaces, unicode)
T4="$SANDBOX/t4.jsonl"
python3 -c 'import json,sys; sys.stdout.write(json.dumps({"type":"custom-title","customTitle":"fix \"auth\" bug ☃","sessionId":"s"})+"\n")' > "$T4"
assert_eq 'fix "auth" bug ☃' "$(last_custom_title "$T4")" "special characters preserved"

# Missing file => empty, no crash
assert_eq "" "$(last_custom_title "$SANDBOX/does-not-exist.jsonl")" "missing transcript => empty"

print_summary
