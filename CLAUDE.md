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
  lib/
    project-slug.sh   # compute_project_slug(): CamelCase 2-chars-per-word slug
    session-title.sh  # last_custom_title(): reads the user's /rename title from the transcript
tests/
  run-tests.sh        # Runs every test-*.sh
  test-project-slug.sh
  test-session-start.sh
  test-session-title.sh
  lib/assert.sh       # Tiny test helpers
```

No build system or package manager — pure bash. Run `bash tests/run-tests.sh`.

## Key Architecture Decisions

- **Non-blocking**: `set-tab-title.sh` spawns a background subshell (`disown`) to avoid blocking Claude Code
- **Tab ownership**: Uses `/tmp/claude-tab-titles/owner-<TAB_KEY>` to guard against stale writes landing in a new session's tab
- **TTY detection**: Prefers `$CMUX_SURFACE_ID` (cmux multiplexer); falls back to `stat -f '%Lr' /dev/tty`
- **Title persistence**: Saved to `/tmp/claude-tab-titles/<session_id>`; restored on UserPromptSubmit with 0.5s delay
- **Haiku model**: `claude-haiku-4-5-20251001` with `--effort low` and all hooks/sessions/tools disabled for speed
- **`/rename` override**: `/rename <name>` writes `{"type":"custom-title","customTitle":...}` to the transcript (it fires no hook). The hooks read that, suppress Haiku, and record a `<session>.rename` marker until the user renames to a different value. Auto-generated `"ai-title"` entries are ignored — only explicit renames win. Behavior differs by terminal:
  - **cmux** already displays the renamed session natively, so the hooks just clear cc-tab-titles' own override (`cmux tab-action --action clear-name`) and defer to cmux — they do not set a competing title. session-start.sh does the same when resuming an already-named session, avoiding a project-name flash.
  - **Other terminals** have no native session name, so the rename value is written to the tab title via OSC.

## Development Notes

- Run the test suite with `bash tests/run-tests.sh` before committing
- Test hooks manually by running the scripts with a mock JSON payload piped to stdin
- Enable debug logging with `CC_TAB_TITLES_DEBUG=1`; logs go to `/tmp/claude-tab-titles/debug.log`
- The plugin is installed via `/plugin install cc-tab-titles@STRML`

## Sandbox Considerations

- The nested `claude -p` call requires `excludedCommands: ["bash ~/.claude/:*"]` in sandbox settings
- Hook `PATH` is restricted — external binaries must be in restricted PATH
- `CMUX_SURFACE_ID` may not be available in sandbox hook environment
