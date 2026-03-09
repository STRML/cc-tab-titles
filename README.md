# cc-tab-titles

A Claude Code plugin that automatically sets your terminal tab title to an AI-generated summary of what you're working on.

**Before:** Every tab shows `Claude Code`
**After:** Tabs show things like `Fixing sandbox hook exclusions` or `Building React dashboard`

## How It Works

- **Stop hook** — after each Claude response, generates a 4-6 word summary using Haiku and sets the tab title via OSC escape sequences. Runs in the background so it doesn't block.
- **UserPromptSubmit hook** — restores the saved title a moment after you submit a message, preventing Claude Code from resetting the title while it's thinking.

## Installation

```bash
/plugin marketplace add STRML/cc-tab-titles
/plugin install cc-tab-titles@STRML
```

Restart Claude Code after installing.

## Requirements

- `claude` CLI in your PATH (used for Haiku summarization)
- A terminal that supports OSC 0 title sequences (Ghostty, iTerm2, Terminal.app, most others)
- `python3` and `jq` available

## Keeping the Title During Thinking

Claude Code resets the tab title when it starts processing. The `UserPromptSubmit` hook handles this with a short delay, but for fully persistent titles, add the included `statusline.sh` to your `statusLine` config — it re-applies the saved title every ~300ms:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash \"${HOME}/.claude/plugins/cache/STRML/cc-tab-titles/1.0.0/hooks/statusline.sh\""
  }
}
```

## Sandbox Note

If you use Claude Code's sandbox mode, add this to your `excludedCommands` in `~/.claude/settings.json` so the nested `claude -p` call can reach the API:

```json
{
  "sandbox": {
    "excludedCommands": ["bash ~/.claude/:*"]
  }
}
```

(This is usually already present if you use other hooks.)

## License

MIT
