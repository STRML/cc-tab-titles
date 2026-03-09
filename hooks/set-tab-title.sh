#!/bin/bash
# Stop hook: generate AI tab title summary and set the terminal tab title.
# Runs claude -p in a background subshell so Claude Code is not blocked.
# Set CC_TAB_TITLES_DEBUG=1 to enable debug logging to /tmp/claude-tab-titles/debug.log

TITLE_DIR=/tmp/claude-tab-titles
mkdir -p "$TITLE_DIR"

_log() { [ -n "$CC_TAB_TITLES_DEBUG" ] && echo "[$(date +%T)] $*" >> "$TITLE_DIR/debug.log"; }

_log "START cmux_surface=${CMUX_SURFACE_ID:-none}"

if [ -n "$CMUX_SURFACE_ID" ]; then
  TAB_KEY="cmux-$CMUX_SURFACE_ID"
else
  exec 3>/dev/tty 2>/dev/null || { _log "SKIP: no tty"; exit 0; }
  TAB_KEY=$(stat -f '%Lr' /dev/tty 2>/dev/null)
fi
_log "TAB_KEY=$TAB_KEY"

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

_log "session=$SESSION"
[ -z "$TRANSCRIPT" ] && { _log "SKIP: no transcript"; exit 0; }

[ -n "$TAB_KEY" ] && [ -n "$SESSION" ] && printf '%s' "$SESSION" > "$TITLE_DIR/owner-$TAB_KEY"

(
  # Redirect inherited fds so Claude Code doesn't wait for this subshell to exit
  if [ -n "$CC_TAB_TITLES_DEBUG" ]; then
    exec >> "$TITLE_DIR/debug.log" 2>&1 < /dev/null
  else
    exec > /dev/null 2>&1 < /dev/null
  fi

  _log() { echo "[$(date +%T)] $*"; }

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

  [ -z "$CONTEXT" ] && { _log "SKIP: no context"; exit 0; }

  _log "calling claude -p"

  SUMMARY=$(CLAUDECODE="" CLAUDE_CODE_ENTRYPOINT="" CLAUDE_CODE_SIMPLE=1 \
    claude -p \
      --model claude-haiku-4-5-20251001 \
      --effort low \
      --no-session-persistence \
      --tools "" \
      --disable-slash-commands \
      --strict-mcp-config \
      --settings '{"disableAllHooks":true}' \
      "Summarize what is being worked on in 30 characters or less. Reply with ONLY the summary, no punctuation, no quotes:

$CONTEXT" 2>/dev/null | tr -d '"' | head -1)

  _log "summary='$SUMMARY'"
  [ -z "$SUMMARY" ] && exit 0

  # Verify ownership (another session may have started in this tab while we ran)
  if [ -n "$TAB_KEY" ]; then
    OWNER=$(cat "$TITLE_DIR/owner-$TAB_KEY" 2>/dev/null)
    if [ "$OWNER" != "$SESSION" ]; then
      _log "SKIP: owner changed"
      exit 0
    fi
  fi

  [ -n "$SESSION" ] && printf '%s' "$SUMMARY" > "$TITLE_DIR/$SESSION"

  if [ -n "$CMUX_SURFACE_ID" ]; then
    RESULT=$(cmux rename-tab --surface "$CMUX_SURFACE_ID" "$SUMMARY" 2>&1)
    _log "cmux exit=$? result='$RESULT'"
  else
    printf '\033]0;%s\007' "$SUMMARY" >&3
  fi

  _log "DONE"
) &
disown

exit 0
