#!/bin/bash
# The shared, detached BASE worktree used to re-run a failing check on the base (stage 4 triage). Never the main checkout:
# build/lint there would write .next/dist/.turbo and can break a running dev server.
#   base-worktree.sh acquire <ticket-id> <commit-ish> --repo <repo-root>   # prints the worktree path; exit 3 = tracked changes in it, 4 = held by another ticket
#   base-worktree.sh release <ticket-id> --repo <repo-root>
# Path: <repo>/.claude/worktrees/_base (same root as ticket worktrees, excluded by init). Created once (git worktree add --detach),
# then moved to the ticket's base commit with `checkout --detach`; env files linked and dependencies installed by setup-worktree.sh
# (no port block). One ticket holds it at a time (lock in the git common dir). It is never removed here: removal needs the user's OK.
# All git work on the repo happens inside this script, so a ticket session only runs one skill-script command.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cmd=${1:-}; id=${2:-}; shift 2 2>/dev/null || true
commit=""; repo=""
if [ "$cmd" = acquire ]; then commit=${1:-}; shift || true; fi
while [ $# -gt 0 ]; do case "$1" in --repo) repo=${2:-}; shift 2;; *) echo "base-worktree: unknown argument $1" >&2; exit 2;; esac; done
[ -n "$cmd" ] && [ -n "$id" ] && [ -n "$repo" ] || { sed -n 2,7p "$0" >&2; exit 2; }
common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)
lock=$common/deliver-ticket-base.lock
W=$repo/.claude/worktrees/_base
case "$cmd" in
  acquire)
    [ -n "$commit" ] || { echo "base-worktree: need a commit" >&2; exit 2; }
    sha=$(git -C "$repo" rev-parse --verify "$commit^{commit}")
    if mkdir "$lock" 2>/dev/null; then echo "$id" > "$lock/ticket"
    else
      holder=$(cat "$lock/ticket" 2>/dev/null || echo "?")
      [ "$holder" = "$id" ] || { echo "base-worktree: held by ticket $holder; release it first (lock: $lock)" >&2; exit 4; }
    fi
    if [ ! -d "$W" ]; then
      git -C "$repo" worktree add -q --detach "$W" "$sha" >&2 || { rm -f "$lock/ticket"; rmdir "$lock"; exit 1; }
    else
      if [ -n "$(git -C "$W" status --porcelain --untracked-files=no)" ]; then
        echo "base-worktree: $W has tracked changes; not touching it - tell the user" >&2; rm -f "$lock/ticket"; rmdir "$lock"; exit 3
      fi
      git -C "$W" checkout -q --detach "$sha" >&2
    fi
    DT_NO_PORTS=1 "$here/setup-worktree.sh" "$repo" "$W" "_base" >&2 || echo "base-worktree: setup-worktree failed (env links / install); the checks may fail for that reason" >&2
    echo "$W"
    ;;
  release)
    holder=$(cat "$lock/ticket" 2>/dev/null || echo "")
    [ "$holder" = "$id" ] || { echo "base-worktree: not held by $id (holder: ${holder:-none})" >&2; exit 4; }
    rm -f "$lock/ticket"; rmdir "$lock"; echo "released"
    ;;
  *) echo "base-worktree: unknown command $cmd" >&2; exit 2;;
esac
