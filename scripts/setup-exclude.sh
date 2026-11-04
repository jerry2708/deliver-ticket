#!/bin/bash
# Add ".claude/worktrees/" to the repo's local exclude file (<git-common-dir>/info/exclude).
# Local git metadata only: never committed, never touches .gitignore. Idempotent.
# Usage: setup-exclude.sh [--check]   (--check: only report; exit 0 if present, 1 if missing)
set -u
LINE='.claude/worktrees/'
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "not in a git repo" >&2; exit 2; }
file="$common/info/exclude"
if [ -f "$file" ] && grep -qxF "$LINE" "$file"; then echo "present: $LINE in $file"; exit 0; fi
if [ "${1:-}" = "--check" ]; then echo "missing: $LINE in $file"; exit 1; fi
mkdir -p "$common/info" || exit 2
# keep an existing last line intact: add a newline first if the file doesn't end with one
if [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ]; then printf '\n' >> "$file"; fi
printf '%s\n' "$LINE" >> "$file" || exit 2
echo "added: $LINE to $file"
