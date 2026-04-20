#!/bin/bash
# Unit tests for compute_project_slug
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/../hooks/lib/project-slug.sh"

echo "test-project-slug.sh"

assert_eq "CcTaTi" "$(compute_project_slug cc-tab-titles)" "three hyphen-words -> 6 char CamelCase"
assert_eq "MyAp"   "$(compute_project_slug my-app)"        "two hyphen-words -> 4 char CamelCase"
assert_eq "Front"  "$(compute_project_slug frontend)"      "single word -> first 5 chars title-cased"
assert_eq "Ai"     "$(compute_project_slug ai)"            "two-letter single word stays 2 chars"
assert_eq "CcSiMe" "$(compute_project_slug cc_simple_memory)" "underscores treated as separators"
assert_eq "RuAuWo" "$(compute_project_slug rush-auto-works)" "three-word capped at 6"
assert_eq "X"      "$(compute_project_slug x)"             "single char single word"
assert_eq "MyAp"   "$(compute_project_slug my--app)"       "empty token from double hyphen ignored"
assert_eq "MyAp"   "$(compute_project_slug my_app_)"       "trailing underscore ignored as empty word"

# Length guarantees
slug=$(compute_project_slug cc-tab-titles); assert_le ${#slug} 6 "slug never exceeds 6 chars (multi-word)"
slug=$(compute_project_slug supercalifragilisticexpialidocious); assert_le ${#slug} 6 "slug never exceeds 6 chars (long single word -> 5)"
assert_eq "Super" "$(compute_project_slug supercalifragilisticexpialidocious)" "single word truncated to 5"

# Determinism
a=$(compute_project_slug cc-tab-titles)
b=$(compute_project_slug cc-tab-titles)
assert_eq "$a" "$b" "deterministic"

print_summary
