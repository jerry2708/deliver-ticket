#!/bin/bash
# deliver-ticket hook: session-record (SessionStart startup|resume|clear). Runs in EVERY repo and directory (user level), needs no guard.json and no python.
# Writes <state root>/starts/<session_id> = the physical path of the payload `cwd`, ONCE: the first SessionStart of an id wins (noclobber = O_EXCL), so resume, compact
# and a nested `claude --resume <id>` cannot change it. The record answers "which directory was this session started in", which Claude cannot change later (the hook
# payload cwd follows a `cd`, probe 2026-11-16, so it cannot answer that). Used by hooks/dtcore.py (C9b) for the rule "the skill repo may be edited only from a session started in it".
# Never blocks, never prints: a problem leaves no record, and no record means "not started in the skill repo" (fail-closed for whoever reads it).
. "$(dirname "$0")/lib.sh"
PAYLOAD=$(cat)
sid=$(printf '%s' "$PAYLOAD" | sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p' | head -n 1)
cwd=$(printf '%s' "$PAYLOAD" | sed -n 's/.*"cwd" *: *"\([^"]*\)".*/\1/p' | head -n 1)
case "$sid" in ""|*[!A-Za-z0-9._-]*|.*) exit 0 ;; esac
[ -n "$cwd" ] && [ -d "$cwd" ] || exit 0
phys=$(cd "$cwd" 2>/dev/null && pwd -P) || exit 0
dir=$DT_HOME/starts
[ -L "$dir" ] && exit 0                     # a planted link would send the record elsewhere
mkdir -p "$dir" 2>/dev/null || exit 0
[ -L "$dir" ] || [ -d "$dir" ] || exit 0
[ -L "$dir" ] && exit 0
f=$dir/$sid
[ -e "$f" ] || [ -L "$f" ] && exit 0        # first record wins
( set -C; printf '%s\n' "$phys" > "$f" ) 2>/dev/null
exit 0
