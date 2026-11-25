#!/bin/bash
# base-worktree.sh: detached shared base worktree, never the main checkout. Usage: tests/run-base-worktree.sh <new scratch dir>
# C11c3: bookkeeping (runs unsandboxed): argument validation, base-branch commits only, repo hooks off, no install (setup-worktree.sh <repo> <_base> _base does that).
# Never deletes anything.
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
[ "$(cd "$SK" && pwd -P)" = "$(cd "$HOME/.claude/skills/deliver-ticket" 2>/dev/null && pwd -P)" ] && echo "warning: this suite tests the LIVE checkout $SK - build and test in the dev clone (docs/plan.md, dev-copy process)" >&2
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
export DELIVER_TICKET_HOME=$S/state
R=$S/repo; [ -e "$R" ] && { echo "scratch dir already used: $S" >&2; exit 2; }
newrepo() { mkdir -p "$1" && git -C "$1" init -q -b main && git -C "$1" config user.email t@t && git -C "$1" config user.name t && echo '.claude/worktrees/' >> "$1/.git/info/exclude"; }
keyof() { printf '%s-%s' "$(basename "$1")" "$(printf '%s' "$1" | shasum -a 1 | cut -c1-8)"; }
guard() { local key; key=$(keyof "$1"); mkdir -p "$DELIVER_TICKET_HOME/$key"; cat > "$DELIVER_TICKET_HOME/$key/guard.json" <<J
{"version":1,"project_key":"$key","repo_root":"$2","base_branch":"main",
 "remotes":{"push":"mirror","allowed":["mirror"],"forbidden":["origin"]},
 "verify":{"lint":"true","test":"true","build":null,"on_push":["lint"],"timeout_sec":20},
 "env_files":[".env.local"],"install":"touch installed.marker","ports":{"vars":["PORT"],"base":3100,"step":10},"allowlist_extra":[]}
J
}
ticket() { local st; st=$DELIVER_TICKET_HOME/$(keyof "$1"); shift; mkdir -p "$st/tickets"; for t in "$@"; do printf '# %s\n\nstate: active\n' "$t" > "$st/tickets/$t.md"; done; }
newrepo "$R" && cd "$R" || exit 1
echo one > f.txt; printf 'FAKE=1\n' > .env.local; git add f.txt && git commit -q -m c1; C1=$(git rev-parse HEAD)
echo two > f.txt; git commit -qam c2; C2=$(git rev-parse HEAD)
mkdir d; echo x > d/x.txt; git add d; git commit -qm c3-dir; C3=$(git rev-parse HEAD)
git checkout -q -b work/t1; echo ticket > f.txt; git commit -qam ticket; CT=$(git rev-parse HEAD); git checkout -q main
guard "$R" "$R"; ticket "$R" T1 T2 T3; mkdir -p "$DELIVER_TICKET_HOME/$(keyof "$R")/closed"; echo x > "$DELIVER_TICKET_HOME/$(keyof "$R")/closed/T3"
B=$SK/scripts/base-worktree.sh; W=$R/.claude/worktrees/_base; L=$R/.git/deliver-ticket-base.lock
pass=0; fail=0
eq() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
rc() { "$@" >"$S/out.txt" 2>&1; echo $?; }
main_before=$(git -C "$R" status --porcelain; git -C "$R" rev-parse HEAD)

echo "# C11c3 refusals (exit 2, git-safe:) before anything exists: nothing created"
eq "$(rc $B acquire T1 "$CT" --repo "$R")" 2 "ticket commit (not on main) refused"; grep -q "not on the base branch" "$S/out.txt"; eq $? 0 "says why"
eq "$(rc $B acquire T1 work/t1 --repo "$R")" 2 "ticket branch name refused"
eq "$(rc $B acquire T1 -x --repo "$R")" 2 "leading dash refused"
eq "$(rc $B acquire T1 --upload-pack=x --repo "$R")" 2 "option-like commit refused"
eq "$(rc $B acquire T1 nosuchref --repo "$R")" 2 "unknown commit refused"
eq "$(rc $B acquire ../x "$C1" --repo "$R")" 2 "path id refused"
eq "$(rc $B acquire _base "$C1" --repo "$R")" 2 "_base is not a ticket id"
eq "$(rc $B acquire T9 "$C1" --repo "$R")" 2 "no ticket file -> not a ticket of this project"; grep -q "not a ticket of this project" "$S/out.txt"; eq $? 0 "says not a ticket"
eq "$(rc $B acquire T3 "$C1" --repo "$R")" 2 "closed ticket refused"; grep -q "is closed" "$S/out.txt"; eq $? 0 "says closed"
eq "$(rc $B acquire T1 "$C1")" 2 "missing --repo"
eq "$(rc $B acquire T1 "$C1" --repo "$R" --extra)" 2 "extra argument"
eq "$(rc $B frobnicate T1 --repo "$R")" 2 "unknown command"
R2=$S/other; newrepo "$R2"; git -C "$R2" commit -q --allow-empty -m o
eq "$(rc $B acquire T1 HEAD --repo "$R2")" 2 "repo without delivery state refused"
guard "$R2" "$R"; ticket "$R2" T1
eq "$(rc $B acquire T1 HEAD --repo "$R2")" 2 "guard.json repo_root of another repo refused"; grep -q "not guard.json repo_root" "$S/out.txt"; eq $? 0 "says repo_root"
git -C "$R" worktree add -q "$S/linked" -b work/linked "$C1"
eq "$(rc $B acquire T1 "$C1" --repo "$S/linked")" 2 "a linked worktree is not the main checkout"
eq "$(rc $B acquire T1 "$C1" --repo "$R/nosuchdir")" 2 "a path that is not a directory refused"
# a risky key from a config file inside the repo (here under .claude/worktrees/, excluded from status; not _base)
mkdir -p "$R/.claude/worktrees"; printf '[core]\n\thooksPath = /x\n' > "$R/.claude/worktrees/evil.cfg"; git -C "$R" config include.path ../.claude/worktrees/evil.cfg
eq "$(rc $B acquire T1 "$C1" --repo "$R")" 2 "risky config from a file inside the repo refused"; grep -q "inside the repository" "$S/out.txt"; eq $? 0 "says config origin"
git -C "$R" config --unset include.path
[ ! -e "$W" ] && [ ! -e "$L" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL a refused call created _base or the lock"; }

echo "# hooks off: a post-checkout hook in the repo does not run"
mkdir -p "$R/.git/hooks"; printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$S" > "$R/.git/hooks/post-checkout"; chmod +x "$R/.git/hooks/post-checkout"

out=$($B acquire T1 "$C1" --repo "$R" 2>/dev/null); eq "$?" 0 "acquire rc"; eq "$out" "$W" "acquire prints the path (only the path on stdout)"
eq "$(git -C "$W" rev-parse HEAD)" "$C1" "base at c1"; eq "$(git -C "$W" symbolic-ref -q HEAD || echo detached)" detached "detached"
eq "$(git -C "$W" rev-parse --show-toplevel)" "$W" "own toplevel"
[ ! -e "$S/hook-ran" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL post-checkout hook ran on worktree add"; }
[ ! -e "$W/.env.local" ] && [ ! -e "$W/installed.marker" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL acquire linked env files or installed (that is setup-worktree.sh's job, sandboxed)"; }

echo "# setup-worktree.sh <repo> <_base> _base: env links + install, no port block"
$SK/scripts/setup-worktree.sh "$R" "$W" _base >/dev/null 2>&1; eq "$?" 0 "setup _base rc"
[ -L "$W/.env.local" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL env file not linked"; }
[ -e "$W/installed.marker" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL install did not run"; }
ls "$DELIVER_TICKET_HOME/$(keyof "$R")/ports" 2>/dev/null | grep -q '^_base$' && { fail=$((fail+1)); echo "FAIL a port block was allocated for _base"; } || pass=$((pass+1))

echo "# same ticket again, new commit: moves the same worktree"
out=$($B acquire T1 "$C2" --repo "$R" 2>/dev/null); eq "$?" 0 "re-acquire rc"; eq "$(git -C "$W" rev-parse HEAD)" "$C2" "moved to c2"
[ ! -e "$S/hook-ran" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL post-checkout hook ran on checkout"; }
eq "$(git -C "$R" worktree list | grep -c '_base')" 1 "one _base worktree"
eq "$(rc $B acquire T1 "$CT" --repo "$R")" 2 "ticket commit refused while held"; eq "$(git -C "$W" rev-parse HEAD)" "$C2" "not moved by the refused call"

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

echo "# a symlink planted in _base where the target commit has a tracked dir: git refuses, lock released, nothing written through it"
out=$($B acquire T1 "$C1" --repo "$R" 2>/dev/null); eq "$?" 0 "acquire at c1 (no d/)"
mkdir -p "$S/target"; echo marker > "$S/target/marker"; ln -s "$S/target" "$W/d"; tbefore=$(ls -laR "$S/target")
eq "$(rc $B acquire T1 "$C3" --repo "$R")" 1 "checkout over the planted symlink fails"; grep -q "untracked working tree files would be overwritten" "$S/out.txt"; eq $? 0 "git's reason"
eq "$(ls -laR "$S/target")" "$tbefore" "symlink target unchanged (listing before / after)"; eq "$(git -C "$W" rev-parse HEAD)" "$C1" "_base not moved"
[ ! -e "$L" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL lock still held after the failed checkout"; }
echo "# _base/.git repointed to a gitdir outside <common>/worktrees -> 2"
R5=$S/r5; newrepo "$R5"; git -C "$R5" commit -q --allow-empty -m r5; guard "$R5" "$R5"; ticket "$R5" T1
$B acquire T1 HEAD --repo "$R5" >/dev/null 2>&1; eq "$?" 0 "r5 acquire"; $B release T1 --repo "$R5" >/dev/null 2>&1
cp -R "$R5/.git/worktrees/_base" "$S/fakegd"; echo "$R5/.git" > "$S/fakegd/commondir"; echo "gitdir: $S/fakegd" > "$R5/.claude/worktrees/_base/.git"   # absolute commondir: passes the common-dir check
eq "$(rc $B acquire T1 HEAD --repo "$R5")" 2 "repointed gitfile refused"; grep -q "does not point to its own entry" "$S/out.txt"; eq $? 0 "says gitfile"
echo "# _base that is not this repo's registered worktree: symlink, plain dir -> 2, target untouched"
R3=$S/r3; newrepo "$R3"; git -C "$R3" commit -q --allow-empty -m r3; guard "$R3" "$R3"; ticket "$R3" T1
mkdir -p "$S/elsewhere" "$R3/.claude/worktrees"; ln -s "$S/elsewhere" "$R3/.claude/worktrees/_base"
eq "$(rc $B acquire T1 HEAD --repo "$R3")" 2 "symlinked _base refused"; eq "$(ls -A "$S/elsewhere" | wc -l | tr -d ' ')" 0 "symlink target untouched"
R4=$S/r4; newrepo "$R4"; git -C "$R4" commit -q --allow-empty -m r4; guard "$R4" "$R4"; ticket "$R4" T1; mkdir -p "$R4/.claude/worktrees/_base"
eq "$(rc $B acquire T1 HEAD --repo "$R4")" 2 "plain-dir _base refused"

echo "# main checkout untouched"
eq "$( (git -C "$R" status --porcelain; git -C "$R" rev-parse HEAD) )" "$main_before" "main checkout status/HEAD"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
