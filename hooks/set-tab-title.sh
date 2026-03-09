#!/bin/bash
# Stop hook: generate AI tab title summary, save it, and set the terminal tab title.

TITLE_DIR=/tmp/claude-tab-titles
mkdir -p "$TITLE_DIR"

# Prefer CMUX_SURFACE_ID as the stable per-tab key; fall back to TTY minor number
if [ -n "$CMUX_SURFACE_ID" ]; then
  TAB_KEY="cmux-$CMUX_SURFACE_ID"
else
  # Open /dev/tty as fd 3 BEFORE backgrounding — after disown, /dev/tty is inaccessible
  # but an already-open fd survives
  exec 3>/dev/tty 2>/dev/null || exit 0
  TAB_KEY=$(stat -f '%Lr' /dev/tty 2>/dev/null)
fi

STDIN=$(cat)

SESSION=$(echo "$STDIN" | python3 -c "
import json, sys
try: print(json.load(sys.stdin).get('session_id', ''))
except: print('')
" 2>/dev/null)

TRANSCRIPT=$(echo "$STDIN" | python3 -c "
import json, sys
try: print(json.load(sys.stdin).get('transcript_path', ''))
except: print('')
" 2>/dev/null)

[ -z "$TRANSCRIPT" ] && exit 0

# Record this session as the current owner of this tab.
[ -n "$TAB_KEY" ] && [ -n "$SESSION" ] && printf '%s' "$SESSION" > "$TITLE_DIR/owner-$TAB_KEY"

(
  # Redirect inherited fds so Claude Code doesn't wait for this subshell to exit
  exec > /dev/null 2>&1 < /dev/null

  CONTEXT=$(python3 -c "
import json, sys
lines = []
try:
    with open('$TRANSCRIPT') as f:
        for line in f:
            try:
                r = json.loads(line)
                msg = r.get('message') or r
                role = msg.get('role', '')
                if role == 'user':
                    for b in msg.get('content', []):
                        if isinstance(b, dict) and b.get('type') == 'text':
                            lines.append('U: ' + b['text'][:120])
                elif role == 'assistant':
                    for b in msg.get('content', []):
                        if isinstance(b, dict) and b.get('type') == 'text':
                            lines.append('A: ' + b['text'][:120])
            except: pass
except: pass
print('\n'.join(lines[-10:])[-800:])
" 2>/dev/null)

  [ -z "$CONTEXT" ] && exit 0

  SUMMARY=$(CLAUDECODE="" CLAUDE_CODE_ENTRYPOINT="" CLAUDE_CODE_SIMPLE=1 \
    claude -p \
      --model claude-haiku-4-5-20251001 \
      --effort low \
      --no-session-persistence \
      --tools "" \
      --disable-slash-commands \
      --strict-mcp-config \
      --settings '{"disableAllHooks":true}' \
      "In 4-6 words, summarize what is being worked on. Reply with ONLY the summary, no punctuation, no quotes:

$CONTEXT" 2>/dev/null | tr -d '"' | head -1)

  [ -z "$SUMMARY" ] && exit 0

  # Verify we still own this tab — a new session may have started while claude -p ran
  if [ -n "$TAB_KEY" ]; then
    OWNER=$(cat "$TITLE_DIR/owner-$TAB_KEY" 2>/dev/null)
    [ "$OWNER" != "$SESSION" ] && exit 0
  fi

  [ -n "$SESSION" ] && printf '%s' "$SUMMARY" > "$TITLE_DIR/$SESSION"

  if [ -n "$CMUX_SURFACE_ID" ]; then
    cmux rename-tab --surface "$CMUX_SURFACE_ID" "$SUMMARY"
  else
    printf '\033]0;%s\007' "$SUMMARY" >&3
  fi
) &
disown

exit 0
