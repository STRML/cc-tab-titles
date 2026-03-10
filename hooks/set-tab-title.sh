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

# Single Python pass: compute user-message hash and write context to .ctx file.
# Hash is over all user text content (stable across invocations).
# Context guarantees the latest user message is included even after long tool-use chains.
USER_HASH=$(python3 - << PYEOF 2>/dev/null
import json, hashlib

transcript = '$TRANSCRIPT'
ctx_file = '$TITLE_DIR/$SESSION.ctx'
lines = []
user_texts = []
latest_user = None

try:
    with open(transcript) as f:
        for line in f:
            try:
                r = json.loads(line)
                msg = r.get('message') or r
                role = msg.get('role', '')
                if role == 'user':
                    for b in msg.get('content', []):
                        if isinstance(b, dict) and b.get('type') == 'text':
                            user_texts.append(b['text'])
                            latest_user = 'U: ' + b['text'][:120]
                    if latest_user:
                        lines.append(latest_user)
                elif role == 'assistant':
                    for b in msg.get('content', []):
                        if isinstance(b, dict) and b.get('type') == 'text':
                            lines.append('A: ' + b['text'][:120])
            except:
                pass
except:
    pass

h = hashlib.md5(''.join(user_texts).encode()).hexdigest()
ctx_lines = lines[-10:]
if latest_user and latest_user not in ctx_lines:
    ctx_lines = [latest_user] + ctx_lines[-9:]
ctx = '\n'.join(ctx_lines)[-800:]

with open(ctx_file, 'w') as f:
    f.write(ctx)

print(h)
PYEOF
)

[ -z "$USER_HASH" ] && { _log "SKIP: hash failed"; exit 0; }

# Hash pre-filter: skip Haiku call if no new user messages since last title write
STORED_HASH=$(cat "$TITLE_DIR/$SESSION.uhash" 2>/dev/null)
if [ "$USER_HASH" = "$STORED_HASH" ]; then
  _log "SKIP: hash unchanged"
  exit 0
fi

# Write hash synchronously before background fork.
# This ensures the hash advances even when Haiku returns UNCHANGED,
# preventing redundant re-triggers on subsequent turns.
printf '%s' "$USER_HASH" > "$TITLE_DIR/$SESSION.uhash"

# Compute deterministic project slug from git root name.
# Uses initials of hyphen/underscore-delimited words, max 6 chars.
# Note: bare git rev-parse (no -C flag) to avoid sandbox auto-allow issues.
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
PROJECT_NAME=$(basename "$PROJECT_ROOT")
PROJECT_SLUG=$(echo "$PROJECT_NAME" | sed 's/[-_]/ /g' | awk '{for(i=1;i<=NF;i++) printf substr($i,1,1)}' | cut -c1-6)
[ ${#PROJECT_SLUG} -le 1 ] && PROJECT_SLUG=$(echo "$PROJECT_NAME" | cut -c1-6)
_log "slug=$PROJECT_SLUG"

CURRENT_TITLE=$(cat "$TITLE_DIR/$SESSION" 2>/dev/null)

(
  # Redirect inherited fds so Claude Code doesn't wait for this subshell to exit
  if [ -n "$CC_TAB_TITLES_DEBUG" ]; then
    exec >> "$TITLE_DIR/debug.log" 2>&1 < /dev/null
  else
    exec > /dev/null 2>&1 < /dev/null
  fi

  _log() { echo "[$(date +%T)] $*"; }

  CONTEXT=$(cat "$TITLE_DIR/$SESSION.ctx" 2>/dev/null)
  [ -z "$CONTEXT" ] && { _log "SKIP: no context"; exit 0; }

  # Write prompt to file via Python to safely handle all special characters.
  # Never interpolate project name or transcript content into shell command strings.
  python3 - << PYEOF 2>/dev/null
slug = '$PROJECT_SLUG'
current = '$CURRENT_TITLE' or 'none'
import os
ctx = open('$TITLE_DIR/$SESSION.ctx').read()
prompt = (
    f"You set terminal tab titles. Project slug (use exactly): [{slug}]\n"
    f"Current title: {current}\n\n"
    f"Recent conversation:\n{ctx}\n\n"
    f"Rules:\n"
    f"- Reply UNCHANGED if the topic has not materially shifted from the current title\n"
    f"- Otherwise reply with a new title: [{slug}] objective\n"
    f"- Total must be <=30 characters including brackets and space\n"
    f"- Fill the objective to fit the 30-char budget after [{slug}] \n"
    f"- Brackets are required format\n"
    f"- No trailing punctuation, no quotes\n"
    f"- Reply with ONLY the title or the word UNCHANGED"
)
open('$TITLE_DIR/$SESSION.prompt', 'w').write(prompt)
PYEOF

  [ -f "$TITLE_DIR/$SESSION.prompt" ] || { _log "SKIP: prompt write failed"; exit 0; }

  _log "calling claude -p"

  SUMMARY=$(CLAUDECODE="" CLAUDE_CODE_ENTRYPOINT="" CLAUDE_CODE_SIMPLE=1 \
    claude -p \
      --model claude-haiku-4-5-20251001 \
      --effort low \
      --no-session-persistence \
      --tools "" \
      --disable-slash-commands \
      --strict-mcp-config \
      --max-tokens 40 \
      --settings '{"disableAllHooks":true}' \
      < "$TITLE_DIR/$SESSION.prompt" 2>/dev/null | tr -d '"' | head -1)

  _log "raw='$SUMMARY'"

  # Normalize and check for UNCHANGED sentinel
  SUMMARY_NORM=$(echo "$SUMMARY" | xargs | tr '[:lower:]' '[:upper:]')
  if echo "$SUMMARY_NORM" | grep -qE '^UNCHANGED[^A-Z]*$'; then
    _log "SKIP: unchanged"
    exit 0
  fi

  # Hard truncation backstop at 30 chars
  SUMMARY=$(echo "$SUMMARY" | xargs | cut -c1-30)
  [ -z "$SUMMARY" ] && { _log "SKIP: empty summary"; exit 0; }

  _log "summary='$SUMMARY'"

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
