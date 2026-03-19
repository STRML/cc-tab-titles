# cc-tab-titles: Improvements Design Spec

**Date:** 2026-03-19
**Status:** Approved

## Overview

Ten improvements to the cc-tab-titles Claude Code plugin covering Linux compatibility, security fixes, performance, configurability, and polish.

## Changes

### 1. Remove `jq` from README requirements

README lists `jq` as required but no script uses it. Remove from requirements section.

### 2. Linux compatibility for `stat`

`stat -f '%Lr'` is macOS-only. Add platform detection in both `set-tab-title.sh` and `session-start.sh`. The fd 3 open to `/dev/tty` must happen before the stat on both platforms (preserving the current interleaving):

```bash
exec 3>/dev/tty 2>/dev/null || { _log "SKIP: no tty"; exit 0; }
if [[ "$(uname)" == "Darwin" ]]; then
  TAB_KEY=$(stat -f '%Lr' /dev/tty 2>/dev/null)
else
  TAB_KEY=$(stat -c '%t:%T' /dev/tty 2>/dev/null)
fi
```

Note: TAB_KEY format differs across platforms (decimal on macOS, hex on Linux) — this is fine since they're only used as local map keys, never shared.

### 3. Shell injection fix — env vars for all surviving Python

All Python snippets receive data via environment variables instead of `'$VAR'` shell interpolation into Python string literals. This prevents breakage/injection from session IDs or paths containing quotes.

**This is a live bug, not just hardening.** `$CURRENT_TITLE` is Haiku-generated output — if Haiku returns a title containing a single quote (e.g. `[ctt] fix user's bug`), the Python literal `'fix user's bug'` is a syntax error and no title is written. Similarly, `$TRANSCRIPT` and file paths containing quotes would break the hash+context Python block.

After item 4 removes Python from `session-start.sh` and `restore-title.sh`, this applies only to scripts that still use Python:
- `set-tab-title.sh` — both Python blocks (hash+context extractor, and prompt writer in background subshell): transcript path, title dir, session ID, project slug, current title
- `statusline.sh` — the consolidated single-pass Python (implemented together with item 7)

Pattern:
```bash
TITLE_DIR="$TITLE_DIR" SESSION_ID="$SESSION" python3 -c "
import os
title_dir = os.environ['TITLE_DIR']
session = os.environ['SESSION_ID']
"
```

### 4. Reduce Python invocations

- `session-start.sh`: Replace `python3` session_id extraction with pure bash:
  ```bash
  SESSION=$(grep -o '"session_id" *: *"[^"]*"' | head -1 | cut -d'"' -f4)
  ```
  (Pattern allows optional whitespace around `:` to handle both compact and formatted JSON. Assumes hook payloads are single-line JSON objects — consistent with observed Claude Code behavior.)
- `restore-title.sh`: Same pure bash extraction.
- `statusline.sh`: Collapse 3 separate `python3` calls into 1 (see item 7). Items 3 and 7 are implemented together for this file.

`set-tab-title.sh` keeps Python for the hash+context pass (unavoidable complexity).

### 5. Temp file cleanup

Add to `session-start.sh` (runs once per session start — good trigger point):

```bash
find "$TITLE_DIR" -type f -not -name 'owner-*' -mtime +1 -delete 2>/dev/null
```

Cleans `.ctx`, `.prompt`, `.uhash`, and title files older than 24 hours. Excludes `owner-*` from the 24h window.

Additionally, clean `owner-*` files older than 7 days (these accumulate on macOS which doesn't clear `/tmp` on reboot):

```bash
find "$TITLE_DIR" -type f -name 'owner-*' -mtime +7 -delete 2>/dev/null
```

### 6. Configurable model and effort

In `set-tab-title.sh`:

```bash
MODEL="${CC_TAB_TITLES_MODEL:-claude-haiku-4-5-20251001}"
EFFORT="${CC_TAB_TITLES_EFFORT:-low}"
```

Used in the `claude -p` invocation: replace `--model claude-haiku-4-5-20251001` with `--model "$MODEL"` and `--effort low` with `--effort "$EFFORT"`.

### 7. Statusline.sh — single Python pass (consolidates with items 3 & 4 for this file)

Collapse 3 `python3` invocations into 1, using env vars (item 3) and eliminating redundant Python spawns (item 4):

```bash
VALS=$(echo "$INPUT" | python3 -c "
import json, sys, os
d = json.load(sys.stdin)
print(d.get('session_id', ''))
print(d.get('model', {}).get('display_name', ''))
print(os.path.basename(d.get('workspace', {}).get('current_dir', '')))
" 2>/dev/null)
SESSION=$(echo "$VALS" | sed -n '1p')
MODEL=$(echo "$VALS" | sed -n '2p')
DIR=$(echo "$VALS" | sed -n '3p')
```

Note: `statusline.sh` runs as a statusLine command, not a hook. The payload schema is assumed to match hook payloads (session_id, model, workspace). The entire Python block must be wrapped in `try/except` to prevent all-or-nothing failures — if the payload shape differs, emit empty strings rather than crashing. The `.get()` calls handle missing keys; the `try/except` handles fundamentally different payloads.

### 8. Initial title on SessionStart

After claiming tab ownership in `session-start.sh`, compute the project slug and set an initial title `[slug] new session`.

Assumes Claude Code sets cwd to the project directory when invoking hooks (consistent with observed behavior). Uses `git rev-parse --show-toplevel` with `$PWD` fallback.

The fd 3 lifecycle in `session-start.sh` needs restructuring: currently opens fd 3 then immediately closes it. Instead, keep fd 3 open until after the title write:

```bash
exec 3>/dev/tty 2>/dev/null || exit 0
# ... stat for TAB_KEY ...
# ... ownership claim ...
# ... compute slug, write title file ...
printf '\033]0;%s\007' "$TITLE" >&3
exec 3>&-
```

For cmux, use `cmux rename-tab` instead.

### 9. Version bump

Bump from `1.0.0` to `1.1.0` in:
- `.claude-plugin/plugin.json`
- `.claude-plugin/marketplace.json`

### 10. README updates

- Remove `jq` from requirements
- Replace "4-6 word summary" with description of `[slug] objective` format
- Document env vars: `CC_TAB_TITLES_MODEL`, `CC_TAB_TITLES_EFFORT`, `CC_TAB_TITLES_DEBUG`
- Mention Linux compatibility
- Update statusline config example (remove hardcoded version path)

## Slug Computation (shared pattern, duplicated)

Slug logic duplicated in `set-tab-title.sh` and `session-start.sh`:

```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
PROJECT_NAME=$(basename "$PROJECT_ROOT")
PROJECT_SLUG=$(echo "$PROJECT_NAME" | sed 's/[-_]/ /g' | awk '{for(i=1;i<=NF;i++) printf substr($i,1,1)}' | cut -c1-6)
[ ${#PROJECT_SLUG} -le 1 ] && PROJECT_SLUG=$(echo "$PROJECT_NAME" | cut -c1-6)
```

No shared script file — duplication is preferable to the complexity of sourcing a shared file across plugin hooks.

## Files Modified

| File | Changes |
|------|---------|
| `hooks/set-tab-title.sh` | Env vars for Python (#3), Linux stat (#2), configurable model/effort (#6) |
| `hooks/session-start.sh` | Pure bash JSON (#4), Linux stat (#2), temp cleanup (#5), initial title (#8), slug |
| `hooks/restore-title.sh` | Pure bash JSON extraction (#4) |
| `hooks/statusline.sh` | Single Python pass with env vars (#3, #4, #7) |
| `.claude-plugin/plugin.json` | Version 1.1.0 (#9) |
| `.claude-plugin/marketplace.json` | Version 1.1.0 (#9) |
| `README.md` | Requirements, description, env vars, Linux note (#1, #10) |

## Implementation Order

Items should be implemented per-file to avoid throwaway work:
1. `session-start.sh` — items 2, 4, 5, 8 (slug + initial title)
2. `restore-title.sh` — item 4
3. `set-tab-title.sh` — items 2, 3, 6
4. `statusline.sh` — items 3, 4, 7 (all together)
5. Version bump + README — items 1, 9, 10

## Non-goals

- No shared script/sourcing infrastructure
- No test framework (pure bash, manually testable)
- No changes to `hooks.json` hook definitions
