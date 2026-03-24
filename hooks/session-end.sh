#!/bin/bash
# SessionEnd hook: reset tab title and clean up temp files when session exits.

TITLE_DIR=/tmp/claude-tab-titles

STDIN=$(cat)
SESSION=$(echo "$STDIN" | grep -o '"session_id" *: *"[^"]*"' | head -1 | cut -d'"' -f4)

[ -z "$SESSION" ] && exit 0

# Reset tab title to CWD basename (what the shell would normally show)
DEFAULT_TITLE=$(basename "$PWD")

if [ -n "$CMUX_SURFACE_ID" ]; then
  cmux rename-tab --surface "$CMUX_SURFACE_ID" "$DEFAULT_TITLE" 2>/dev/null
elif [ -n "$TMUX" ]; then
  tmux rename-window "$DEFAULT_TITLE" 2>/dev/null
else
  exec 3>/dev/tty 2>/dev/null && printf '\033]0;%s\007' "$DEFAULT_TITLE" >&3
fi

# Clean up session temp files
rm -f "$TITLE_DIR/$SESSION" "$TITLE_DIR/$SESSION.uhash" \
      "$TITLE_DIR/$SESSION.ctx" "$TITLE_DIR/$SESSION.prompt" \
      "$TITLE_DIR/$SESSION.pinned"

# Release tab ownership
if [ -n "$CMUX_SURFACE_ID" ]; then
  TAB_KEY="cmux-$CMUX_SURFACE_ID"
elif [[ "$(uname)" == "Darwin" ]]; then
  TAB_KEY=$(stat -f '%Lr' /dev/tty 2>/dev/null)
else
  TAB_KEY=$(stat -c '%t:%T' /dev/tty 2>/dev/null)
fi
[ -n "$TAB_KEY" ] && rm -f "$TITLE_DIR/owner-$TAB_KEY"

exit 0
