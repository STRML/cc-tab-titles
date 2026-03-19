# cc-tab-titles Improvements Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply 10 improvements to the cc-tab-titles plugin: Linux compatibility, shell injection fix, reduced Python invocations, configurable model/effort, initial session title, temp cleanup, statusline consolidation, version bump, and README updates.

**Architecture:** Per-file implementation order to avoid throwaway work. Pure bash scripts with embedded Python where needed. No test framework — verify with manual dry-run commands and shellcheck.

**Tech Stack:** Bash, Python3 (embedded), Claude CLI

**Spec:** `docs/superpowers/specs/2026-03-19-improvements-design.md`

---

## Chunk 1: session-start.sh

### Task 1: Rewrite session-start.sh

**Files:**
- Modify: `hooks/session-start.sh`

The current script is 28 lines. The rewrite touches nearly every line (pure bash JSON, Linux stat, fd 3 lifecycle, slug, initial title, cleanup), so write the full replacement.

- [ ] **Step 1: Write the new session-start.sh**

Replace the entire file with:

```bash
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

# Compute project slug and set initial title
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
PROJECT_NAME=$(basename "$PROJECT_ROOT")
PROJECT_SLUG=$(echo "$PROJECT_NAME" | sed 's/[-_]/ /g' | awk '{for(i=1;i<=NF;i++) printf substr($i,1,1)}' | cut -c1-6)
[ ${#PROJECT_SLUG} -le 1 ] && PROJECT_SLUG=$(echo "$PROJECT_NAME" | cut -c1-6)

TITLE="[$PROJECT_SLUG] new session"
TITLE=$(echo "$TITLE" | cut -c1-30)
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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n hooks/session-start.sh`
Expected: no output (clean parse)

- [ ] **Step 3: Dry-run with mock payload**

Run: `echo '{"session_id": "test-abc-123"}' | bash hooks/session-start.sh`
Expected: exits 0, creates `/tmp/claude-tab-titles/test-abc-123` with initial title

- [ ] **Step 4: Verify the title file was written**

Run: `cat /tmp/claude-tab-titles/test-abc-123`
Expected: something like `[cct] new session` (slug depends on cwd)

- [ ] **Step 5: Clean up test artifact and commit**

Run: `rm -f /tmp/claude-tab-titles/test-abc-123`

```bash
git add hooks/session-start.sh
git commit -m "feat(session-start): pure bash JSON, Linux stat, initial title, temp cleanup

- Replace python3 JSON extraction with grep/cut (spec #4)
- Add Linux-compatible stat for TAB_KEY (spec #2)
- Set initial [slug] title on session start (spec #8)
- Clean temp files >24h, owner files >7d (spec #5)"
```

---

## Chunk 2: restore-title.sh

### Task 2: Replace Python with pure bash in restore-title.sh

**Files:**
- Modify: `hooks/restore-title.sh`

- [ ] **Step 1: Replace the python3 session_id extraction**

In `hooks/restore-title.sh`, replace lines 12-16:

```bash
SESSION=$(echo "$STDIN" | python3 -c "
import json, sys
try: print(json.load(sys.stdin).get('session_id', ''))
except: print('')
" 2>/dev/null)
```

With:

```bash
SESSION=$(echo "$STDIN" | grep -o '"session_id" *: *"[^"]*"' | head -1 | cut -d'"' -f4)
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n hooks/restore-title.sh`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add hooks/restore-title.sh
git commit -m "perf(restore-title): replace python3 with pure bash JSON extraction

Eliminates python3 spawn for session_id parsing (spec #4)"
```

---

## Chunk 3: set-tab-title.sh

### Task 3: Apply improvements to set-tab-title.sh

**Files:**
- Modify: `hooks/set-tab-title.sh`

Four changes: Linux stat (#2), env vars for Python (#3), configurable model/effort (#6), fold session_id/transcript_path extraction into the hash+context Python pass (#4).

**Note:** Line numbers shift after each step. Use the content patterns (old/new blocks) for matching, not line numbers. Line numbers are approximate starting points.

- [ ] **Step 1: Add Linux-compatible stat**

Replace the stat block (around lines 16-18):

```bash
  exec 3>/dev/tty 2>/dev/null || { _log "SKIP: no tty"; exit 0; }
  TAB_KEY=$(stat -f '%Lr' /dev/tty 2>/dev/null)
```

With:

```bash
  exec 3>/dev/tty 2>/dev/null || { _log "SKIP: no tty"; exit 0; }
  if [[ "$(uname)" == "Darwin" ]]; then
    TAB_KEY=$(stat -f '%Lr' /dev/tty 2>/dev/null)
  else
    TAB_KEY=$(stat -c '%t:%T' /dev/tty 2>/dev/null)
  fi
```

- [ ] **Step 2: Fold session_id and transcript_path extraction into pure bash**

Replace the two separate Python blocks that extract `session_id` and `transcript_path` (around lines 21-33):

Old:
```bash
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
```

New:
```bash
STDIN=$(cat)

# Pure bash JSON extraction — eliminates 2 python3 spawns
SESSION=$(echo "$STDIN" | grep -o '"session_id" *: *"[^"]*"' | head -1 | cut -d'"' -f4)
TRANSCRIPT=$(echo "$STDIN" | grep -o '"transcript_path" *: *"[^"]*"' | head -1 | cut -d'"' -f4)
```

- [ ] **Step 3: Add configurable model and effort**

After the `_log "slug=$PROJECT_SLUG"` line, add:

```bash
MODEL="${CC_TAB_TITLES_MODEL:-claude-haiku-4-5-20251001}"
EFFORT="${CC_TAB_TITLES_EFFORT:-low}"
```

Then in the `claude -p` invocation, replace:

```bash
      --model claude-haiku-4-5-20251001 \
      --effort low \
```

With:

```bash
      --model "$MODEL" \
      --effort "$EFFORT" \
```

- [ ] **Step 4: Fix shell injection — env vars for first Python block (hash+context)**

Replace the first Python heredoc (the `USER_HASH=` block). The current code interpolates `$TRANSCRIPT` and `$TITLE_DIR/$SESSION.ctx` as Python string literals. Replace with env vars:

Old:
```bash
USER_HASH=$(python3 - << PYEOF 2>/dev/null
import json, hashlib

transcript = '$TRANSCRIPT'
ctx_file = '$TITLE_DIR/$SESSION.ctx'
...
PYEOF
)
```

New:
```bash
USER_HASH=$(CC_TRANSCRIPT="$TRANSCRIPT" CC_CTX_FILE="$TITLE_DIR/$SESSION.ctx" python3 - << 'PYEOF' 2>/dev/null
import json, hashlib, os

transcript = os.environ['CC_TRANSCRIPT']
ctx_file = os.environ['CC_CTX_FILE']
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
```

Key changes:
- Heredoc delimiter is now `'PYEOF'` (quoted — prevents all shell interpolation)
- `$TRANSCRIPT` and ctx file path passed via `CC_TRANSCRIPT` and `CC_CTX_FILE` env vars
- Python reads from `os.environ` instead of string literals

- [ ] **Step 5: Fix shell injection — env vars for second Python block (prompt writer)**

Replace the prompt-writing Python block inside the background subshell. Currently interpolates `$PROJECT_SLUG`, `$CURRENT_TITLE`, `$TITLE_DIR/$SESSION.ctx`, `$TITLE_DIR/$SESSION.prompt`:

Old:
```bash
  python3 - << PYEOF 2>/dev/null
slug = '$PROJECT_SLUG'
current = '$CURRENT_TITLE' or 'none'
import os
ctx = open('$TITLE_DIR/$SESSION.ctx').read()
...
open('$TITLE_DIR/$SESSION.prompt', 'w').write(prompt)
PYEOF
```

New:
```bash
  CC_SLUG="$PROJECT_SLUG" CC_CURRENT="${CURRENT_TITLE:-none}" \
  CC_CTX_FILE="$TITLE_DIR/$SESSION.ctx" CC_PROMPT_FILE="$TITLE_DIR/$SESSION.prompt" \
  python3 - << 'PYEOF' 2>/dev/null
import os
slug = os.environ['CC_SLUG']
current = os.environ['CC_CURRENT']
ctx = open(os.environ['CC_CTX_FILE']).read()
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
open(os.environ['CC_PROMPT_FILE'], 'w').write(prompt)
PYEOF
```

Key changes:
- Heredoc delimiter quoted (`'PYEOF'`) to prevent shell interpolation
- All values passed via `CC_*` env vars
- `$CURRENT_TITLE` default handled in bash (`${CURRENT_TITLE:-none}`) not Python

- [ ] **Step 6: Verify syntax**

Run: `bash -n hooks/set-tab-title.sh`
Expected: no output

- [ ] **Step 7: Commit**

```bash
git add hooks/set-tab-title.sh
git commit -m "fix(set-tab-title): shell injection, Linux stat, configurable model

- Pass all Python data via env vars, quote heredoc delimiters (spec #3)
- Fixes live bug: Haiku titles with quotes broke Python literals
- Replace python3 session_id/transcript_path with pure bash (spec #4)
- Add Linux-compatible stat for TAB_KEY (spec #2)
- Configurable CC_TAB_TITLES_MODEL and CC_TAB_TITLES_EFFORT (spec #6)"
```

---

## Chunk 4: statusline.sh

### Task 4: Consolidate statusline.sh Python into single pass

**Files:**
- Modify: `hooks/statusline.sh`

- [ ] **Step 1: Rewrite statusline.sh**

Replace the entire file:

```bash
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
```

Key changes:
- 3 `python3` calls → 1
- `try/except` wraps entire block, emitting 3 empty lines on failure
- No shell variable interpolation into Python — stdin-only, so env vars aren't needed (spec #3 lists statusline.sh but the env var pattern is specifically to prevent shell interpolation into Python literals; since this script passes all data via stdin/`json.load`, there's nothing to interpolate)
- Removed old hardcoded version path from comment; uses `${CLAUDE_PLUGIN_ROOT}`

- [ ] **Step 2: Verify syntax**

Run: `bash -n hooks/statusline.sh`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add hooks/statusline.sh
git commit -m "perf(statusline): consolidate 3 python3 calls into 1

Single-pass JSON extraction with try/except for robustness (spec #3, #4, #7)"
```

---

## Chunk 5: Version bump + README

### Task 5: Version bump

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Bump plugin.json version**

Change `"version": "1.0.0"` to `"version": "1.1.0"` in `.claude-plugin/plugin.json`.

- [ ] **Step 2: Bump marketplace.json version**

Change `"version": "1.0.0"` to `"version": "1.1.0"` in `.claude-plugin/marketplace.json`.

- [ ] **Step 3: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore: bump version to 1.1.0"
```

### Task 6: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README**

Apply these changes to `README.md`:

1. Replace the description line:
   - Old: `generates a 4-6 word summary using Haiku and sets the tab title`
   - New: `generates a short \`[slug] objective\` summary using Haiku and sets the tab title`

2. Add `SessionStart` hook to the "How It Works" section:
   - Add: `- **SessionStart hook** — claims tab ownership and sets an initial \`[slug] new session\` title.`

3. Replace the Requirements section:
   - Old: `- \`python3\` and \`jq\` available`
   - New: `- \`python3\` available`

4. Add a "Configuration" section after Requirements:

```markdown
## Configuration

Set these environment variables to customize behavior:

| Variable | Default | Description |
|----------|---------|-------------|
| `CC_TAB_TITLES_MODEL` | `claude-haiku-4-5-20251001` | Model for title generation |
| `CC_TAB_TITLES_EFFORT` | `low` | Effort level for the model |
| `CC_TAB_TITLES_DEBUG` | (unset) | Set to `1` for debug logging to `/tmp/claude-tab-titles/debug.log` |
```

5. Add a "Platform Support" note after Configuration:

```markdown
## Platform Support

Works on both macOS and Linux. Terminal tab title setting uses OSC escape sequences supported by Ghostty, iTerm2, Terminal.app, and most modern terminals.
```

6. Update the statusline config example — replace the hardcoded path:
   - Old: `"command": "bash \"${HOME}/.claude/plugins/cache/STRML/cc-tab-titles/1.0.0/hooks/statusline.sh\""`
   - New: `"command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/statusline.sh\""`

- [ ] **Step 2: Verify README renders correctly**

Skim the file to confirm markdown structure is valid.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: update README for v1.1.0

- Remove jq from requirements (spec #1)
- Document [slug] objective format and SessionStart hook
- Add Configuration section with env vars (spec #10)
- Add Platform Support section (spec #10)
- Fix statusline config example to use CLAUDE_PLUGIN_ROOT"
```
