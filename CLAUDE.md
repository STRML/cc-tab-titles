# cc-tab-titles

A Claude Code plugin that sets terminal tab titles to AI-generated summaries of what's being worked on.

## Project Structure

```
hooks/
  hooks.json          # Hook definitions (SessionStart, Stop, UserPromptSubmit)
  set-tab-title.sh    # Stop hook: generates summary via claude -p (Haiku), writes OSC title
  session-start.sh    # SessionStart hook: claims tab ownership for new session
  restore-title.sh    # UserPromptSubmit hook: re-applies saved title after Claude resets it
  statusline.sh       # Optional statusLine command to keep title persistent
```

No build system, no package manager, no tests — pure bash scripts.

## Key Architecture Decisions

- **Non-blocking**: `set-tab-title.sh` spawns a background subshell (`disown`) to avoid blocking Claude Code
- **Tab ownership**: Uses `/tmp/claude-tab-titles/owner-<TAB_KEY>` to guard against stale writes landing in a new session's tab
- **TTY detection**: Prefers `$CMUX_SURFACE_ID` (cmux multiplexer); falls back to `stat -f '%Lr' /dev/tty`
- **Title persistence**: Saved to `/tmp/claude-tab-titles/<session_id>`; restored on UserPromptSubmit with 0.5s delay
- **Haiku model**: `claude-haiku-4-5-20251001` with `--effort low` and all hooks/sessions/tools disabled for speed

## Development Notes

- Test hooks manually by running the scripts with a mock JSON payload piped to stdin
- Enable debug logging with `CC_TAB_TITLES_DEBUG=1`; logs go to `/tmp/claude-tab-titles/debug.log`
- The plugin is installed via `/plugin install cc-tab-titles@STRML`

## Sandbox Considerations

- The nested `claude -p` call requires `excludedCommands: ["bash ~/.claude/:*"]` in sandbox settings
- Hook `PATH` is restricted — external binaries must be in restricted PATH
- `CMUX_SURFACE_ID` may not be available in sandbox hook environment
