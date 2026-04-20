#!/bin/bash
# compute_project_slug <project-name>
# Prints a CamelCase slug derived from a hyphen/underscore-delimited name.
# Multi-word: 2 chars per word, capped at 6 chars total (e.g. cc-tab-titles -> CcTaTi).
# Single-word: first 5 chars, title-cased (e.g. frontend -> Front).
# Aims for 4-5+ chars unless the source name is shorter.
compute_project_slug() {
  local name="$1"
  local slug
  slug=$(echo "$name" | awk -F'[-_]' '{
    if (NF <= 1) {
      s = substr($1, 1, 5)
      printf "%s%s", toupper(substr(s,1,1)), substr(s,2)
    } else {
      out = ""
      for (i=1; i<=NF; i++) {
        if ($i == "") continue
        part = substr($i, 1, 2)
        out = out toupper(substr(part,1,1)) substr(part,2)
      }
      printf "%s", substr(out, 1, 6)
    }
  }')
  [ -z "$slug" ] && slug=$(echo "$name" | cut -c1-6)
  printf '%s' "$slug"
}
