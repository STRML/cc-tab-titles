#!/bin/bash
# last_custom_title <transcript_path>
# Echoes the most recent user-set session title (from `/rename`) found in the
# transcript, or nothing if the user never renamed. Claude Code records a
# `/rename <name>` as a line {"type":"custom-title","customTitle":"<name>"};
# auto-generated titles use type "ai-title" and are intentionally ignored here.
last_custom_title() {
  CC_TITLE_TRANSCRIPT="$1" python3 - << 'PYEOF' 2>/dev/null
import json, os
path = os.environ['CC_TITLE_TRANSCRIPT']
title = ''
try:
    with open(path) as f:
        for line in f:
            try:
                d = json.loads(line)
                if d.get('type') == 'custom-title':
                    title = d.get('customTitle') or ''
            except Exception:
                pass
except Exception:
    pass
print(title)
PYEOF
}
