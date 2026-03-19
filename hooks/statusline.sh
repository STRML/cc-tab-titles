#!/bin/bash
# Optional: add to your statusLine config to keep the title persistent
# even while Claude is actively thinking (updates every ~300ms).
#
# Usage in ~/.claude/settings.json:
#   "statusLine": {
#     "type": "command",
#     "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/statusline.sh\""
#   }

TITLE_DIR=/tmp/claude-tab-titles

INPUT=$(cat)

# Single Python pass to extract all needed values
VALS=$(echo "$INPUT" | python3 -c "
import json, sys, os
try:
    d = json.load(sys.stdin)
    print(d.get('session_id', ''))
    print(d.get('model', {}).get('display_name', ''))
    print(os.path.basename(d.get('workspace', {}).get('current_dir', '')))
except:
    print('')
    print('')
    print('')
" 2>/dev/null)
SESSION=$(echo "$VALS" | sed -n '1p')
MODEL=$(echo "$VALS" | sed -n '2p')
DIR=$(echo "$VALS" | sed -n '3p')

# Restore tab title if we have a saved one
if [ -n "$SESSION" ]; then
  TITLE_FILE="$TITLE_DIR/$SESSION"
  if [ -f "$TITLE_FILE" ]; then
    TITLE=$(cat "$TITLE_FILE")
    [ -n "$TITLE" ] && printf '\033]0;%s\007' "$TITLE" > /dev/tty 2>/dev/null
  fi
fi

# Emit a minimal status line (model + directory)
[ -n "$MODEL" ] && echo "[$MODEL] $DIR"
