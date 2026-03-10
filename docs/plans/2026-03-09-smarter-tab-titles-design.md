# Smarter Tab Titles Design

**Date:** 2026-03-09
**Status:** Approved (reviewed by Codex/Gemini/Opus, 2 rounds)

## Problem

The current `set-tab-title.sh` Stop hook calls Haiku after every Claude response, unconditionally generating and writing a new title. This causes two issues:

1. **Titles regenerate on every turn** even when the topic hasn't changed, causing flickering and wasted API calls.
2. **Titles are objective-only** — they don't include the project context, making it hard to tell which project a tab belongs to when multiple Claude Code sessions are open.

## Goals

- Title format: `[slug] objective` within 30 characters total
- Only update the title when the conversation topic has materially shifted
- No new dependencies, no new infrastructure — pure bash + existing Haiku call

## Non-Goals

- Persisting titles across machine restarts
- Supporting terminals that don't accept OSC sequences (already handled)
- Changing `restore-title.sh` or `session-start.sh` behavior

---

## Design

### 1. Single Python Pass: Hash + Context Extraction

In a single Python invocation, iterate the transcript JSONL once and produce both:
- **User-message hash**: MD5 (via `hashlib.md5`) of concatenated `text` content from all `role == "user"`, `type == "text"` blocks. Hashing only text content (not IDs, timestamps, etc.) ensures stability.
- **Context window**: Last 10 transcript lines (user + assistant), guaranteed to include the most recent user message even if the last 10 lines are all assistant/tool turns.

The Python pass writes the context to `$TITLE_DIR/$SESSION.ctx` (a temp file) and prints only the MD5 hash to stdout. This avoids a second Python invocation for decoding.

**Context guarantee:** If the most recent user message is not in the last 10 lines (e.g., long tool-use chain), prepend it. This ensures Haiku always sees the user's current intent when the hash changes.

### 2. Hash Pre-Filter

After the Python pass, compare the computed hash to `/tmp/claude-tab-titles/<session_id>.uhash`:

- **Hash matches** → exit immediately, no Haiku call
- **Hash differs** → write the new hash to `.uhash` **immediately in the synchronous path** (before entering the background subshell), then proceed

**Critical**: The hash write happens unconditionally when the hash differs — before the Haiku call, before the background fork. This means:
- Even if Haiku returns `UNCHANGED`, the hash is already updated → next turn won't redundantly re-trigger Haiku
- Narrows the race window vs. writing the hash inside the background subshell

### 3. Deterministic Slug Pre-Computation

Pre-compute a deterministic project slug in bash before calling Haiku:

```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
PROJECT_NAME=$(basename "$PROJECT_ROOT")
# First letter of each hyphen/underscore-delimited word, max 6 chars
PROJECT_SLUG=$(echo "$PROJECT_NAME" | sed 's/[-_]/ /g' | awk '{for(i=1;i<=NF;i++) printf substr($i,1,1)}' | cut -c1-6)
# Fallback: if result is 1 char or empty, use first 6 chars of project name
[ ${#PROJECT_SLUG} -le 1 ] && PROJECT_SLUG=$(echo "$PROJECT_NAME" | cut -c1-6)
```

Note: `git rev-parse --show-toplevel` without `-C` — the hook already runs in the project directory and `-C "$PWD"` breaks sandbox auto-allow.

Pass `PROJECT_SLUG` to Haiku as a fixed value. Haiku only generates the objective portion. This prevents slug inconsistency across invocations (e.g., `cct` vs `cc-tab` vs `tab` for the same project on different turns).

**Why git root**: `$PWD` in a Stop hook may be a subdirectory. The git repository root is a more stable identifier and avoids the `[src]` / `[app]` problem for generically-named project directories. Falls back to `$PWD` if not in a git repo.

### 4. Haiku Call via Prompt File (No Shell Injection)

Write the Haiku prompt to a temp file using a unique heredoc delimiter; pass to claude via stdin redirect. Never interpolate project name or transcript content into the shell command string:

```bash
PROMPT_FILE="$TITLE_DIR/$SESSION.prompt"
CONTEXT=$(cat "$TITLE_DIR/$SESSION.ctx" 2>/dev/null)

cat > "$PROMPT_FILE" << '_END_OF_PROMPT_'
You set terminal tab titles. Project slug (use exactly): [PROJECT_SLUG_PLACEHOLDER]
Current title: CURRENT_TITLE_PLACEHOLDER

Recent conversation:
CONTEXT_PLACEHOLDER

Rules:
- Reply UNCHANGED if the topic has not materially shifted from the current title
- Otherwise reply with a new title: [PROJECT_SLUG_PLACEHOLDER] objective
- Total must be <=30 characters including brackets and space
- Fill the objective to fit the 30-char budget after the slug prefix
- Brackets are required format
- No trailing punctuation, no quotes
- Reply with ONLY the title or the word UNCHANGED
_END_OF_PROMPT_

# Replace placeholders after writing (avoids heredoc variable expansion issues)
sed -i '' \
  -e "s|PROJECT_SLUG_PLACEHOLDER|$PROJECT_SLUG|g" \
  -e "s|CURRENT_TITLE_PLACEHOLDER|${CURRENT_TITLE:-none}|" \
  "$PROMPT_FILE"
# Append context separately to avoid delimiter collision
printf '%s\n' "$CONTEXT" >> "$PROMPT_FILE"
# (Or: write prompt in two parts — static header + dynamic context appended)
```

Alternative cleaner approach: use Python to write the prompt file, safely joining all parts.

**Security**: Project name and context are written to a file and passed via stdin redirect — never interpolated into the shell command string or the `claude -p` argument.

**`--max-tokens 40`**: Added to prevent runaway Haiku responses.

### 5. Response Normalization, UNCHANGED Check, and Truncation

```bash
RESULT=$(... claude -p ... < "$PROMPT_FILE" 2>/dev/null | tr -d '"' | head -1)

# Normalize: strip surrounding whitespace, uppercase for comparison
RESULT_NORM=$(echo "$RESULT" | xargs | tr '[:lower:]' '[:upper:]')

# UNCHANGED check (tolerates trailing punctuation/whitespace)
if echo "$RESULT_NORM" | grep -qE '^UNCHANGED[^A-Z]*$'; then
  exit 0
fi

# Hard truncation backstop at 30 chars
RESULT=$(echo "$RESULT" | xargs | cut -c1-30)
[ -z "$RESULT" ] && exit 0
```

### 6. Write Ordering: Title Before Hash

The hash is written synchronously (Step 2) before the background subshell. Inside the subshell, only the title is written:

```bash
# Title write (inside background subshell, after Haiku returns)
printf '%s' "$RESULT" > "$TITLE_DIR/$SESSION"
# Hash already written synchronously before the fork
```

If killed between the synchronous hash write and the async title write, worst case is a stale title that triggers one redundant Haiku call next turn — far better than a permanently stale title.

### 7. File Layout

| Path | Purpose |
|------|---------|
| `/tmp/claude-tab-titles/<session_id>` | Current title (existing) |
| `/tmp/claude-tab-titles/<session_id>.uhash` | Hash of all user message text (new) |
| `/tmp/claude-tab-titles/<session_id>.ctx` | Context temp file from Python pass (new, overwritten each call) |
| `/tmp/claude-tab-titles/<session_id>.prompt` | Prompt temp file for Haiku (new, overwritten each call) |
| `/tmp/claude-tab-titles/owner-<TAB_KEY>` | Tab ownership guard (existing, unchanged) |

### 8. Unchanged Components

- `session-start.sh` — no changes
- `restore-title.sh` — no changes
- `statusline.sh` — no changes
- `hooks.json` — no changes
- Tab ownership logic — no changes
- fd 3 (`/dev/tty`) setup — no changes; opened before background fork, inherited by subshell

---

## Implementation

All changes confined to `hooks/set-tab-title.sh`.

**Pseudocode:**

```bash
# 0. Setup (existing: TITLE_DIR, TAB_KEY, fd 3, STDIN, SESSION, TRANSCRIPT)

# 1. Single Python pass: compute user-message hash, write context to .ctx file
USER_HASH=$(python3 -c "
import json, sys, hashlib
lines = []
user_texts = []
latest_user = None
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
                            user_texts.append(b['text'])
                            latest_user = 'U: ' + b['text'][:120]
                    if latest_user:
                        lines.append(latest_user)
                elif role == 'assistant':
                    for b in msg.get('content', []):
                        if isinstance(b, dict) and b.get('type') == 'text':
                            lines.append('A: ' + b['text'][:120])
            except: pass
except: pass

h = hashlib.md5(''.join(user_texts).encode()).hexdigest()
ctx_lines = lines[-10:]
if latest_user and latest_user not in ctx_lines:
    ctx_lines = [latest_user] + ctx_lines[-9:]
ctx = '\n'.join(ctx_lines)[-800:]
with open('$TITLE_DIR/$SESSION.ctx', 'w') as f:
    f.write(ctx)
print(h)
" 2>/dev/null)

[ -z "$USER_HASH" ] && exit 0

# 2. Hash pre-filter
STORED_HASH=$(cat "$TITLE_DIR/$SESSION.uhash" 2>/dev/null)
[ "$USER_HASH" = "$STORED_HASH" ] && exit 0

# Write hash synchronously (before background fork)
printf '%s' "$USER_HASH" > "$TITLE_DIR/$SESSION.uhash"

# 3. Compute slug deterministically
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
PROJECT_NAME=$(basename "$PROJECT_ROOT")
PROJECT_SLUG=$(echo "$PROJECT_NAME" | sed 's/[-_]/ /g' | awk '{for(i=1;i<=NF;i++) printf substr($i,1,1)}' | cut -c1-6)
[ ${#PROJECT_SLUG} -le 1 ] && PROJECT_SLUG=$(echo "$PROJECT_NAME" | cut -c1-6)

CURRENT_TITLE=$(cat "$TITLE_DIR/$SESSION" 2>/dev/null)

(
  # Redirect inherited fds (existing pattern)
  exec > /dev/null 2>&1 < /dev/null

  CONTEXT=$(cat "$TITLE_DIR/$SESSION.ctx" 2>/dev/null)

  # 4. Write prompt file using Python to avoid all delimiter/injection issues
  python3 - << 'PYEOF'
import os, sys
title_dir = os.environ.get('TITLE_DIR', '/tmp/claude-tab-titles')  # passed via env or hardcoded
session = '$SESSION'
slug = '$PROJECT_SLUG'
current = '$CURRENT_TITLE' or 'none'
ctx_file = f'{title_dir}/{session}.ctx'
prompt_file = f'{title_dir}/{session}.prompt'
try:
    ctx = open(ctx_file).read()
except:
    ctx = ''
prompt = f"""You set terminal tab titles. Project slug (use exactly): [{slug}]
Current title: {current}

Recent conversation:
{ctx}

Rules:
- Reply UNCHANGED if the topic has not materially shifted from the current title
- Otherwise reply with a new title: [{slug}] objective
- Total must be <=30 characters including brackets and space
- Fill the objective to fit the 30-char budget after [{slug}]
- Brackets are required format
- No trailing punctuation, no quotes
- Reply with ONLY the title or the word UNCHANGED"""
open(prompt_file, 'w').write(prompt)
PYEOF

  # 5. Call Haiku via stdin redirect
  RESULT=$(CLAUDECODE="" CLAUDE_CODE_ENTRYPOINT="" CLAUDE_CODE_SIMPLE=1 \
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

  # 6. Normalize and check UNCHANGED
  RESULT_NORM=$(echo "$RESULT" | xargs | tr '[:lower:]' '[:upper:]')
  echo "$RESULT_NORM" | grep -qE '^UNCHANGED[^A-Z]*$' && exit 0

  # Truncation backstop
  RESULT=$(echo "$RESULT" | xargs | cut -c1-30)
  [ -z "$RESULT" ] && exit 0

  # 7. Ownership check (existing logic unchanged)
  if [ -n "$TAB_KEY" ]; then
    OWNER=$(cat "$TITLE_DIR/owner-$TAB_KEY" 2>/dev/null)
    [ "$OWNER" != "$SESSION" ] && exit 0
  fi

  # 8. Write title
  printf '%s' "$RESULT" > "$TITLE_DIR/$SESSION"

  # 9. OSC write or cmux rename (existing logic unchanged)
  if [ -n "$CMUX_SURFACE_ID" ]; then
    cmux rename-tab --surface "$CMUX_SURFACE_ID" "$RESULT"
  else
    printf '\033]0;%s\007' "$RESULT" >&3
  fi
) &
disown

exit 0
```

---

## Trade-offs Considered

| Approach | Pro | Con | Decision |
|----------|-----|-----|----------|
| Two-phase Haiku call (detect then generate) | Clean separation | Double latency, double API calls | Rejected |
| Hash pre-filter only (no LLM materiality check) | Zero extra calls | Can't detect topic shifts within same user message batch | Partial — used as first gate |
| Single call with UNCHANGED sentinel | One API call, LLM semantics | Haiku must be reliably instructed | **Chosen** |
| Delegating slug abbreviation to Haiku | Simpler prompt | Non-deterministic slug across calls; flicker | Rejected — pre-compute in bash |
| Interpolating `$PROJECT` into `claude -p` arg | Simple | Shell injection via malicious dir name | Rejected — use prompt file + stdin |
| `git -C "$PWD"` for repo root | Explicit | Breaks sandbox auto-allow | Rejected — bare `git rev-parse` |
| Base64 for multiline context transport | Avoids file I/O | Second Python invocation overhead | Rejected — write to `.ctx` file |

---

## Success Criteria

- Tab title includes `[slug]` prefix using git root project name (deterministic across calls)
- Title does not change when user sends follow-up messages on the same topic
- Title changes when user pivots to a new task
- No increase in P50 latency for title updates (same single Haiku call path)
- Shell injection via directory name or transcript content is not possible
- Hash file updated unconditionally when user messages change (even if Haiku returns UNCHANGED)
- Titles hard-capped at 30 chars via `cut -c1-30`
