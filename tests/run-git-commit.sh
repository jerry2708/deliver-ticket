#!/bin/bash
# Tests for scripts/git-commit.sh (the commit gate, C11) and the branch record it trusts (delivery.log `branch` lines, written by worktree-create.sh and
# git-rename.sh). Scratch repos only; DELIVER_TICKET_HOME is redirected into the scratch dir; never deletes anything.
# Usage: tests/run-git-commit.sh <new scratch dir>
set -u
S=${1:?scratch dir (must be new or empty)}
SK=$(cd "$(dirname "$0")/.." && pwd)
[ "$(cd "$SK" && pwd -P)" = "$(cd "$HOME/.claude/skills/deliver-ticket" 2>/dev/null && pwd -P)" ] && echo "warning: this suite tests the LIVE checkout $SK - build and test in the dev clone (docs/plan.md, dev-copy process)" >&2
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
[ -z "$(ls -A "$S")" ] || { echo "scratch dir not empty: $S (pick a new one; the script never deletes anything)" >&2; exit 2; }
export DELIVER_TICKET_HOME=$S/state GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
pass=0; fail=0
req() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; cat "$S/out.txt" 2>/dev/null | head -3; }; }
has() { grep -q -- "$2" "$1" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: [$2] not in $1"; head -3 "$1"; }; }
R=$S/repo
mkdir -p "$R" && git -C "$R" init -q -b main && git -C "$R" config user.email t@t && git -C "$R" config user.name t
echo 1 > "$R/f.txt" && git -C "$R" add f.txt && git -C "$R" commit -q -m init
key=$(bash -c ". \"$SK/hooks/lib.sh\"; dt_key \"$R\""); ST=$DELIVER_TICKET_HOME/$key
mkdir -p "$ST/tickets" "$ST/closed" "$DELIVER_TICKET_HOME/sessions"
python3 -I -c 'import json,sys; g=json.load(open(sys.argv[1])); g.update(project_key=sys.argv[3], repo_root=sys.argv[4], base_branch="main"); json.dump(g, open(sys.argv[2], "w"))' \
  "$SK/tests/guard-json/valid.json" "$ST/guard.json" "$key" "$R"
GC=$SK/scripts/git-commit.sh
log() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import ticket_ctl; ticket_ctl.log(*sys.argv[2:])' "$SK/scripts" "$ST" - "$1" "$2" "$3"; }
# wt <ID> <branch> [record]: a ticket worktree + ticket file with a plan; `record` writes the branch line the WorktreeCreate hook would write
wt() { git -C "$R" worktree add -q "$R/.claude/worktrees/$1" -b "$2" main; printf '# %s\n## Plan\n- step 1\n' "$1" > "$ST/tickets/$1.md"; [ "${3:-}" = record ] && log "$1" branch "$2"; }
approve() { "$SK/scripts/approve-plan.sh" "$1" --sha "$("$SK/scripts/plan-hash.sh" "$1" --repo "$R" 2>/dev/null | awk '{print $3}')" --repo "$R" --session s1 >/dev/null 2>&1; }
gc() { local d=$1; shift; (cd "$d" && "$GC" "$@") >"$S/out.txt" 2>&1; echo $?; }
rn() { local d=$1; shift; (cd "$d" && "$SK/scripts/git-rename.sh" "$@") >"$S/out.txt" 2>&1; echo $?; }
head_of() { git -C "$R" rev-parse "refs/heads/$1"; }
W=$R/.claude/worktrees/T1
wt T1 work/t1 record; approve T1

echo "# a good commit: staged files, approved plan, HEAD on the recorded branch -> commit, logged with branch, staged tree and file list"
echo a > "$W/a.txt"; git -C "$W" add a.txt
tree=$(git -C "$W" write-tree); before=$(head_of work/t1)
req "$(gc "$W" --session s1 -m 'feat: a')" 0 "good commit"
[ "$(head_of work/t1)" != "$before" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL the branch did not move"; }
has "$ST/delivery.log" "| session=s1 | ticket=T1 | commit | $(head_of work/t1) branch=work/t1 tree=$tree files=\[\"a.txt\"\]" "commit record"
echo "# a file staged after the stat was shown is in the logged list (traceable, not blocked)"
echo b > "$W/b.txt"; git -C "$W" add b.txt; git -C "$W" diff --cached --stat >/dev/null; echo late > "$W/late.txt"; git -C "$W" add late.txt
req "$(gc "$W" --session s1 -m 'feat: b')" 0 "commit with a late-staged file"
has "$ST/delivery.log" 'files=\["b.txt", "late.txt"\]' "late file logged"
echo "# -F <message file>: a regular file outside the git dir"
printf 'feat: c\n' > "$S/msg.txt"; echo c > "$W/c.txt"; git -C "$W" add c.txt
req "$(gc "$W" --session s1 -F "$S/msg.txt")" 0 "-F message file"
req "$(git -C "$W" log -1 --format=%s)" "feat: c" "message from the file"
echo "# argument refusals (exit 2, nothing committed)"
echo d > "$W/d.txt"; git -C "$W" add d.txt; before=$(head_of work/t1)
for args in "-m x" "--session s1" "--session s1 -m x -a" "--session s1 -m x --amend" "--session s1 --amend -m x" "--session s1 -m x d.txt" "--session s1 -a -m" \
  "--session s1 --no-verify x" "--session s1 -m" "--session ../x -m x" "--session s1 -F $R/.git/HEAD" "--session s1 -F $S/no-such-file" "--session s1 -F $S" "-m x --session s1 extra"; do
  # shellcheck disable=SC2086
  req "$(gc "$W" $args)" 2 "args: $args"
done
req "$(gc "$W" --session s1 -m '  ')" 2 "empty message"
req "$(head_of work/t1)" "$before" "no refusal committed"
echo "# nothing staged"
git -C "$W" commit -q -m "d (by the test, outside the gate)" >/dev/null 2>&1
req "$(gc "$W" --session s1 -m x)" 2 "nothing staged"
grep -q 'nothing is staged' "$S/out.txt" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL message for nothing staged"; }
echo "# HEAD must be the recorded branch: detached HEAD and another branch are refused (.git/worktrees/<n>/HEAD is writable from the sandbox)"
echo e > "$W/e.txt"; git -C "$W" add e.txt
git -C "$W" checkout -q --detach
req "$(gc "$W" --session s1 -m x)" 2 "detached HEAD"; grep -q 'detached' "$S/out.txt" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL detached message"; }
git -C "$W" checkout -q -b other-branch
req "$(gc "$W" --session s1 -m x)" 2 "HEAD on another branch"; grep -q 'not the ticket.s recorded branch refs/heads/work/t1' "$S/out.txt" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL other-branch message"; }
req "$(git -C "$R" rev-parse -q --verify refs/heads/other-branch^{commit} >/dev/null; echo $?)" 0 "fixture: other-branch exists"
git -C "$W" checkout -q work/t1
echo "# the plan must be approved; the ticket must be open; a branch record must exist; run from a ticket worktree"
wt T2 work/t2 record; echo x > "$R/.claude/worktrees/T2/x.txt"; git -C "$R/.claude/worktrees/T2" add x.txt
req "$(gc "$R/.claude/worktrees/T2" --session s1 -m x)" 2 "plan not approved"; grep -q 'not approved' "$S/out.txt" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL approval message"; }
wt T3 work/t3; approve T3; echo x > "$R/.claude/worktrees/T3/x.txt"; git -C "$R/.claude/worktrees/T3" add x.txt
req "$(gc "$R/.claude/worktrees/T3" --session s1 -m x)" 2 "no branch record"; grep -q 'no branch is recorded' "$S/out.txt" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL no-record message"; }
wt T4 work/t4 record; approve T4; echo x > "$R/.claude/worktrees/T4/x.txt"; git -C "$R/.claude/worktrees/T4" add x.txt; echo x > "$ST/closed/T4"
req "$(gc "$R/.claude/worktrees/T4" --session s1 -m x)" 2 "closed ticket"
req "$(gc "$R" --session s1 -m x)" 2 "run from the main checkout"
echo "# the ticket file's branch: line is not trusted"
printf '# T3\nbranch: work/t3\n## Plan\n- step 1\n' > "$ST/tickets/T3.md"; approve T3
req "$(gc "$R/.claude/worktrees/T3" --session s1 -m x)" 2 "branch: line in the ticket file alone"
echo "# a risky git config key from a file Claude can edit is refused"
printf '[core]\n\tsshCommand = touch %s/ssh-marker\n' "$S" > "$W/inc.cfg"; git -C "$R" config include.path "$W/inc.cfg"
req "$(gc "$W" --session s1 -m x)" 2 "include.path to a worktree file"
git -C "$R" config --unset include.path

echo "# git-rename.sh renames only the recorded branch, and records the new name"
req "$(rn "$R/.claude/worktrees/T3" work/t3 feat/t3)" 2 "rename without a record"
req "$(rn "$W" other-branch feat/x)" 2 "rename a branch that is not checked out / not recorded"
git -C "$W" checkout -q other-branch
req "$(rn "$W" other-branch feat/other)" 2 "rename the checked-out branch that is not the recorded one"
git -C "$W" checkout -q work/t1
req "$(rn "$W" work/t1 feat/t1-thing)" 0 "rename the recorded branch"
has "$ST/delivery.log" "| ticket=T1 | branch | feat/t1-thing" "new name recorded"
req "$(gc "$W" --session s1 -m 'feat: e')" 0 "commit after the rename (record follows)"
has "$ST/delivery.log" "branch=feat/t1-thing" "commit on the renamed branch"
log T1 branch work/old; req "$(rn "$W" feat/t1-thing feat/t1-other)" 2 "rename refused once the record names another branch"

echo "# C11e2: the logged list is the commit's own, renames as delete + add, | escaped so the name survives the log"
log T1 branch feat/t1-thing     # the record again (the rename test above left work/old)
git -C "$W" mv a.txt a2.txt; echo p > "$W/p|q.txt"; git -C "$W" add "p|q.txt"
req "$(gc "$W" --session s1 -m 'refactor: rename a')" 0 "commit with a rename and a | name"
has "$ST/delivery.log" 'files=\["a.txt", "a2.txt", "p\\u007cq.txt"\]$' "rename = delete + add; | as \\u007c"
req "$(python3 -I -c 'import json, re, sys; l = [x for x in open(sys.argv[1]) if "| commit |" in x][-1]; print(json.loads(re.search(r"files=(\[.*\])$", l).group(1))[2])' "$ST/delivery.log")" "p|q.txt" "the JSON gives the exact name back"
req "$(tail -1 "$ST/delivery.log" | grep -o 'tree=[0-9a-f]*' | cut -d= -f2)" "$(git -C "$W" rev-parse 'HEAD^{tree}')" "tree = the commit's tree"
echo "# C11e2: the index changes during the commit (git add right before the real commit) -> committed, MISMATCH logged, exit 3"
# C11e3: the gate's PATH is fixed (scripts/fixed_env.py), so a `git` wrapper on PATH no longer reaches it. git_commit.main runs in-process here, with
# git_safe.run_git wrapped to stage extra.txt first: this exercises the tree / parent check, not the wrapper (the next block tests the wrapper).
echo f > "$W/f.txt"; git -C "$W" add f.txt; echo extra > "$W/extra.txt"; staged=$(git -C "$W" write-tree); before=$(head_of feat/t1-thing)
req "$(cd "$W" && python3 -I -c 'import subprocess, sys; sys.path.insert(0, sys.argv[1]); import git_safe, git_commit
real = git_safe.run_git
def run_git(wt, *a, **k):
    if a and a[0] == "commit":
        subprocess.run(["git", "-C", wt, "add", "extra.txt"], check=True)
    return real(wt, *a, **k)
git_safe.run_git = run_git
sys.exit(git_commit.main(sys.argv[2:]))' "$SK/scripts" --session s1 -m 'feat: f' >"$S/out.txt" 2>&1; echo $?)" 3 "index changed during the commit: exit 3"
has "$S/out.txt" "is not what was staged" "mismatch message"
has "$S/out.txt" "STOP: show the user" "mismatch message says stop"
has "$ST/delivery.log" "MISMATCH staged_tree=$staged head_before=$before files=\\[\"extra.txt\", \"f.txt\"\\]" "MISMATCH line with the commit's files"
req "$(git -C "$W" log -1 --format=%s)" "feat: f" "the commit exists"

echo "# C11e3: the gate's environment is fixed - BASH_ENV, an exported function, PATH, DEVELOPER_DIR, HOME, XDG_CONFIG_HOME, DYLD_* from the caller reach nothing"
E=$S/evil; mkdir -p "$E/bin" "$E/dd/usr/bin" "$E/home" "$E/xdg/git"
for n in python3 git dirname env id xcrun; do printf '#!/bin/sh\ntouch "%s/ran-%s"\nexit 9\n' "$E" "$n" > "$E/bin/$n"; chmod +x "$E/bin/$n"; done
cp "$E/bin/xcrun" "$E/dd/usr/bin/xcrun"
printf 'touch "%s/ran-bash_env"\n' "$E" > "$E/e.sh"
printf '[core]\n\tfsmonitor = touch %s/ran-fsmonitor-home\n' "$E" > "$E/home/.gitconfig"
printf '[core]\n\tfsmonitor = touch %s/ran-fsmonitor-xdg\n' "$E" > "$E/xdg/git/config"
echo g > "$W/g.txt"; git -C "$W" add g.txt
req "$(cd "$W" && env BASH_ENV="$E/e.sh" "BASH_FUNC_exec%%=() { touch $E/ran-func; }" PATH="$E/bin:$PATH" DEVELOPER_DIR="$E/dd" HOME="$E/home" \
  XDG_CONFIG_HOME="$E/xdg" DYLD_INSERT_LIBRARIES="$E/none.dylib" "$GC" --session s1 -m 'feat: g' >"$S/out.txt" 2>&1; echo $?)" 0 "commit under a hostile environment"
req "$(git -C "$W" log -1 --format=%s)" "feat: g" "the hostile-environment commit landed"
req "$(cd "$E" && ls ran-* 2>/dev/null | tr '\n' ' ')" "" "nothing from the caller's environment ran"
# control: the fake HOME config does run under a plain git commit (so the check above is not empty)
echo h > "$S/ctl.txt"; git init -q "$S/ctl" && cp "$S/ctl.txt" "$S/ctl/" && git -C "$S/ctl" add ctl.txt
env -u GIT_CONFIG_GLOBAL HOME="$E/home" git -C "$S/ctl" -c user.email=t@t -c user.name=t commit -q -m ctl >/dev/null 2>&1
req "$(cd "$E" && ls ran-* 2>/dev/null | tr '\n' ' ')" "ran-fsmonitor-home " "control: core.fsmonitor in \$HOME/.gitconfig runs under plain git"

echo "# --separate-git-dir: the scripts refuse with a clear message"
SR=$S/seprepo; git init -q -b main --separate-git-dir "$S/sep.git" "$SR" && git -C "$SR" config user.email t@t && git -C "$SR" config user.name t
echo 1 > "$SR/f.txt" && git -C "$SR" add f.txt && git -C "$SR" commit -q -m init && git -C "$SR" worktree add -q "$SR/.claude/worktrees/S1" -b work/s1 main
echo x > "$SR/.claude/worktrees/S1/x.txt"; git -C "$SR/.claude/worktrees/S1" add x.txt
req "$(gc "$SR/.claude/worktrees/S1" --session s1 -m x)" 2 "separate git dir: gate"
has "$S/out.txt" "separate-git-dir" "separate git dir message"
req "$(rn "$SR/.claude/worktrees/S1" work/s1 feat/s1)" 2 "separate git dir: rename"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
