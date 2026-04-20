#!/bin/bash
# SessionStart hook: claim this tab for the new session and set initial title.
# Prevents a previous session's delayed title write from landing in the wrong tab.

TITLE_DIR=/tmp/claude-tab-titles
mkdir -p "$TITLE_DIR"

# Clean stale temp files (not owner-* which guard long sessions)
find "$TITLE_DIR" -type f -not -name 'owner-*' -mtime +1 -delete 2>/dev/null
# Clean old owner files (macOS doesn't clear /tmp on reboot)
find "$TITLE_DIR" -type f -name 'owner-*' -mtime +7 -delete 2>/dev/null

STDIN=$(cat)

# Pure bash JSON extraction (no python3 dependency)
SESSION=$(echo "$STDIN" | grep -o '"session_id" *: *"[^"]*"' | head -1 | cut -d'"' -f4)
[ -z "$SESSION" ] && exit 0

if [ -n "$CMUX_SURFACE_ID" ]; then
  TAB_KEY="cmux-$CMUX_SURFACE_ID"
else
  exec 3>/dev/tty 2>/dev/null || exit 0
  if [[ "$(uname)" == "Darwin" ]]; then
    TAB_KEY=$(stat -f '%Lr' /dev/tty 2>/dev/null)
  else
    TAB_KEY=$(stat -c '%t:%T' /dev/tty 2>/dev/null)
  fi
fi

[ -n "$TAB_KEY" ] && printf '%s' "$SESSION" > "$TITLE_DIR/owner-$TAB_KEY"

# Clear pinned state from previous session in this tab
rm -f "$TITLE_DIR/$SESSION.pinned"

# Set initial title to the project folder name
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
PROJECT_NAME=$(basename "$PROJECT_ROOT")

TITLE=$(echo "$PROJECT_NAME" | cut -c1-30)
printf '%s' "$TITLE" > "$TITLE_DIR/$SESSION"

if [ -n "$CMUX_SURFACE_ID" ]; then
  cmux rename-tab --surface "$CMUX_SURFACE_ID" "$TITLE" 2>/dev/null
elif [ -n "$TAB_KEY" ]; then
  # fd 3 was opened above for non-cmux path
  printf '\033]0;%s\007' "$TITLE" >&3
fi

# Close fd 3 if it was opened (non-cmux path)
[ -z "$CMUX_SURFACE_ID" ] && exec 3>&- 2>/dev/null

exit 0
