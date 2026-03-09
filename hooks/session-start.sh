#!/bin/bash
# SessionStart hook: claim this tab for the new session.
# Prevents a previous session's delayed title write from landing in the wrong tab.

TITLE_DIR=/tmp/claude-tab-titles
mkdir -p "$TITLE_DIR"

STDIN=$(cat)
SESSION=$(echo "$STDIN" | python3 -c "
import json, sys
try: print(json.load(sys.stdin).get('session_id', ''))
except: print('')
" 2>/dev/null)

[ -z "$SESSION" ] && exit 0

if [ -n "$CMUX_SURFACE_ID" ]; then
  TAB_KEY="cmux-$CMUX_SURFACE_ID"
else
  exec 3>/dev/tty 2>/dev/null || exit 0
  TAB_KEY=$(stat -f '%Lr' /dev/tty 2>/dev/null)
  exec 3>&-
fi

[ -n "$TAB_KEY" ] && printf '%s' "$SESSION" > "$TITLE_DIR/owner-$TAB_KEY"

exit 0
