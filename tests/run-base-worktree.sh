#!/bin/bash
# base-worktree.sh: detached shared base worktree, never the main checkout. Usage: tests/run-base-worktree.sh <new scratch dir>
# Never deletes anything.
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
[ "$(cd "$SK" && pwd -P)" = "$(cd "$HOME/.claude/skills/deliver-ticket" 2>/dev/null && pwd -P)" ] && echo "warning: this suite tests the LIVE checkout $SK - build and test in the dev clone (docs/plan.md, dev-copy process)" >&2
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
export DELIVER_TICKET_HOME=$S/state
R=$S/repo; [ -e "$R" ] && { echo "scratch dir already used: $S" >&2; exit 2; }
mkdir -p "$R" && cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
echo '.claude/worktrees/' >> .git/info/exclude
echo one > f.txt; printf 'FAKE=1\n' > .env.local; git add f.txt && git commit -q -m c1; C1=$(git rev-parse HEAD)
echo two > f.txt; git commit -qam c2; C2=$(git rev-parse HEAD)
key=$(printf '%s-%s' repo "$(printf '%s' "$R" | shasum -a 1 | cut -c1-8)")
mkdir -p "$DELIVER_TICKET_HOME/$key"
cat > "$DELIVER_TICKET_HOME/$key/guard.json" <<J
{"version":1,"project_key":"$key","repo_root":"$R","base_branch":"main",
 "remotes":{"push":"mirror","allowed":["mirror"],"forbidden":["origin"]},
 "verify":{"lint":"true","test":"true","build":null,"on_push":["lint"],"timeout_sec":20},
 "env_files":[".env.local"],"install":"touch installed.marker","ports":{"vars":["PORT"],"base":3100,"step":10},"allowlist_extra":[]}
J
B=$SK/scripts/base-worktree.sh; W=$R/.claude/worktrees/_base
pass=0; fail=0
eq() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
main_before=$(git -C "$R" status --porcelain; git -C "$R" rev-parse HEAD)

out=$($B acquire T1 "$C1" --repo "$R" 2>/dev/null); eq "$?" 0 "acquire rc"; eq "$out" "$W" "acquire prints the path"
eq "$(git -C "$W" rev-parse HEAD)" "$C1" "base at c1"; eq "$(git -C "$W" symbolic-ref -q HEAD || echo detached)" detached "detached"
[ -L "$W/.env.local" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL env file not linked"; }
[ -e "$W/installed.marker" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL install did not run"; }
ls "$DELIVER_TICKET_HOME/$key/ports" 2>/dev/null | grep -q '^_base$' && { fail=$((fail+1)); echo "FAIL a port block was allocated for _base"; } || pass=$((pass+1))
eq "$(git -C "$W" rev-parse --show-toplevel)" "$W" "own toplevel"

echo "# same ticket again, new commit: moves the same worktree"
out=$($B acquire T1 "$C2" --repo "$R" 2>/dev/null); eq "$?" 0 "re-acquire rc"; eq "$(git -C "$W" rev-parse HEAD)" "$C2" "moved to c2"
eq "$(git -C "$R" worktree list | grep -c '_base')" 1 "one _base worktree"

echo "# another ticket while held -> 4"
$B acquire T2 "$C1" --repo "$R" >/dev/null 2>&1; eq "$?" 4 "held by T1"
$B release T2 --repo "$R" >/dev/null 2>&1; eq "$?" 4 "wrong ticket cannot release"

echo "# tracked change in _base -> 3, lock released, nothing touched"
$B release T1 --repo "$R" >/dev/null 2>&1; eq "$?" 0 "release"
echo dirty >> "$W/f.txt"
$B acquire T1 "$C1" --repo "$R" >/dev/null 2>&1; eq "$?" 3 "dirty -> 3"
eq "$(git -C "$W" rev-parse HEAD)" "$C2" "dirty base not moved"
git -C "$W" checkout -q -- f.txt
$B acquire T2 "$C1" --repo "$R" >/dev/null 2>&1; eq "$?" 0 "free after exit 3 (lock was released)"; eq "$(git -C "$W" rev-parse HEAD)" "$C1" "T2 at c1"
$B release T2 --repo "$R" >/dev/null 2>&1; eq "$?" 0 "release T2"

echo "# main checkout untouched"
eq "$( (git -C "$R" status --porcelain; git -C "$R" rev-parse HEAD) )" "$main_before" "main checkout status/HEAD"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
