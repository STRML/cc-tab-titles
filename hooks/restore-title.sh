#!/bin/bash
# UserPromptSubmit hook: restore saved tab title.
# Claude Code resets the title when it starts thinking; this fights that
# by re-applying the saved title shortly after the user submits a message.

TITLE_DIR=/tmp/claude-tab-titles

# In cmux, tab titles aren't overridden by Claude Code's OSC writes, so no restore needed
[ -n "$CMUX_SURFACE_ID" ] && exit 0

STDIN=$(cat)
SESSION=$(echo "$STDIN" | grep -o '"session_id" *: *"[^"]*"' | head -1 | cut -d'"' -f4)

[ -z "$SESSION" ] && exit 0

TITLE_FILE="$TITLE_DIR/$SESSION"
[ -f "$TITLE_FILE" ] || exit 0
TITLE=$(cat "$TITLE_FILE")
[ -z "$TITLE" ] && exit 0

# Open /dev/tty before backgrounding so fd survives disown
exec 3>/dev/tty 2>/dev/null || exit 0

# Small delay to run after Claude Code resets the title
(
  sleep 0.5
  printf '\033]0;%s\007' "$TITLE" >&3
) &
disown

exit 0
