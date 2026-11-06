#!/bin/bash
# WorktreeCreate hook (user level => runs for EVERY repo; replaces Claude Code's default entirely).
# Payload: {session_id, cwd (main checkout), hook_event_name, name}. Contract: print the worktree path on stdout.
# - repo without delivery state: exact default (git worktree add <repo>/.claude/worktrees/<name> -b worktree-<name>)
# - repo with state: branch from guard.json naming + base, env symlinks, deps, port block
# - path already exists: print it, exit 0 (WorktreeCreate fires again on `claude -w <name>`)
# - any error: say why, undo only what this run created, exit 1
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"
PAYLOAD=$(cat)
parsed=$(printf '%s' "$PAYLOAD" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("name","")); print(d.get("cwd",""))') \
  || { echo "worktree-create: payload is not valid JSON" >&2; exit 1; }
name=$(printf '%s\n' "$parsed" | sed -n 1p); cwd=$(printf '%s\n' "$parsed" | sed -n 2p)
case "$name" in ""|*[!A-Za-z0-9._-]*|.*) echo "worktree-create: unsafe or empty worktree name '$name'" >&2; exit 1;; esac
[ -n "$cwd" ] && [ -d "$cwd" ] || { echo "worktree-create: payload cwd missing or not a directory" >&2; exit 1; }
common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || { echo "worktree-create: $cwd is not in a git repo" >&2; exit 1; }
root=${common%/.git}
wt=$root/.claude/worktrees/$name
[ -d "$wt" ] && { printf '%s\n' "$wt"; exit 0; }

created_wt=0; created_branch=""
undo() {  # only what this run created
  [ $created_wt = 1 ] && git -C "$root" worktree remove --force "$wt" >&2 2>&1
  [ -n "$created_branch" ] && git -C "$root" branch -D "$created_branch" >&2 2>&1
  true
}
fail() { echo "worktree-create: $*" >&2; undo; exit 1; }

key=$(dt_key "$cwd") || key=""
guard=$DT_HOME/$key/guard.json
if [ -z "$key" ] || [ ! -f "$guard" ]; then
  base=HEAD
  head=$(git -C "$root" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) && base=${head#refs/remotes/}
  branch=worktree-$name
  git -C "$root" worktree add "$wt" -b "$branch" "$base" >&2 || { echo "worktree-create: git worktree add failed" >&2; exit 1; }
  printf '%s\n' "$wt"; exit 0
fi

# repo with delivery state
read -r base naming < <(python3 -I -c 'import json,sys; g=json.load(open(sys.argv[1])); print(g["base_branch"], g.get("branch_naming") or "feature/{id}-{slug}")' "$guard") \
  || fail "guard.json unreadable at $guard"
# The hook only knows the worktree name (the ticket ID): it fills {id} and {id-lowercase}, uses the provisional type `work`
# and drops {slug}. Stage 1b renames the branch to the full name (scripts/branch-name.py) before the first commit.
idl=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
branch=${naming//\{id-lowercase\}/$idl}; branch=${branch//\{id\}/$name}; branch=${branch//\{type\}/work}; branch=${branch//\{slug\}/}
case $branch in *'{'*|*'}'*) fail "branch_naming '$naming' has a placeholder the hook cannot fill (known: {id} {id-lowercase} {type} {slug})";; esac
branch=$(printf '%s' "$branch" | sed -e 's#//*#/#g' -e 's#/-#/#g' -e 's#^-##' -e 's/[-_.]*$//' -e 's#/*$##')
git check-ref-format --branch "$branch" >/dev/null 2>&1 || fail "branch name '$branch' (from naming rule '$naming') is not valid"
git -C "$root" rev-parse --verify -q "refs/heads/$base" >/dev/null || fail "base branch '$base' does not exist locally"
# remote-tracking refs only (no network inside a hook): a same-named branch on a remote needs my decision
for r in $(git -C "$root" remote); do
  git -C "$root" show-ref --verify -q "refs/remotes/$r/$branch" && fail "branch '$branch' already exists on remote '$r' - stop and ask"
done
if git -C "$root" rev-parse --verify -q "refs/heads/$branch" >/dev/null; then
  git -C "$root" worktree add "$wt" "$branch" >&2 || fail "git worktree add failed (branch $branch exists)"
else
  git -C "$root" worktree add "$wt" -b "$branch" "$base" >&2 || fail "git worktree add failed"
  created_branch=$branch
fi
created_wt=1
"$here/../scripts/setup-worktree.sh" "$root" "$wt" "$name" >&2 || fail "setup-worktree.sh failed"
printf '%s\n' "$wt"
