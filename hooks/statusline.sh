#!/bin/bash
# Optional: add to your statusLine config to keep the title persistent
# even while Claude is actively thinking (updates every ~300ms).
#
# Usage in ~/.claude/settings.json:
#   "statusLine": {
#     "type": "command",
#     "command": "~/.claude/plugins/cache/.../hooks/statusline.sh | your-statusline-script"
#   }
#
# Or replace your statusLine entirely:
#   "statusLine": {
#     "type": "command",
#     "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/statusline.sh\""
#   }

TITLE_DIR=/tmp/claude-tab-titles

INPUT=$(cat)

SESSION=$(echo "$INPUT" | python3 -c "
import json, sys
try: print(json.load(sys.stdin).get('session_id', ''))
except: print('')
" 2>/dev/null)

# Restore tab title if we have a saved one
if [ -n "$SESSION" ]; then
  TITLE_FILE="$TITLE_DIR/$SESSION"
  if [ -f "$TITLE_FILE" ]; then
    TITLE=$(cat "$TITLE_FILE")
    [ -n "$TITLE" ] && printf '\033]0;%s\007' "$TITLE" > /dev/tty 2>/dev/null
  fi
fi

# Emit a minimal status line (model + directory)
MODEL=$(echo "$INPUT" | python3 -c "
import json, sys
try: print(json.load(sys.stdin).get('model', {}).get('display_name', ''))
except: print('')
" 2>/dev/null)

DIR=$(echo "$INPUT" | python3 -c "
import json, sys, os
try: print(os.path.basename(json.load(sys.stdin).get('workspace', {}).get('current_dir', '')))
except: print('')
" 2>/dev/null)

[ -n "$MODEL" ] && echo "[$MODEL] $DIR"
