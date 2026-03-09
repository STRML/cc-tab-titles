#!/bin/bash
# SessionStart hook: claim this TTY for the new session.
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

exec 3>/dev/tty 2>/dev/null || exit 0
TTY_PATH=$(ls -la /dev/fd/3 2>/dev/null | awk '{print $NF}')
TTY_KEY=$(basename "$TTY_PATH")
exec 3>&-

[ -n "$TTY_KEY" ] && printf '%s' "$SESSION" > "$TITLE_DIR/owner-$TTY_KEY"

exit 0
