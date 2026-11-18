#!/bin/bash
# Tests for the plan-approval lock (milestone 1c, C8; plan.md section 3b): a write under the worktree of an open ticket whose plan is not approved is blocked, on every
# route the hooks parse, in a bound and in an unbound session. Usage: tests/run-plan-lock.sh <scratch-dir>. Never deletes or moves anything; the state root is redirected.
set -u
S=${1:?scratch dir (must be new or empty)}
SK=$(cd "$(dirname "$0")/.." && pwd)
[ "$(cd "$SK" && pwd -P)" = "$(cd "$HOME/.claude/skills/deliver-ticket" 2>/dev/null && pwd -P)" ] && echo "warning: this suite tests the LIVE checkout $SK - build and test in the dev clone (docs/plan.md, dev-copy process)" >&2
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
export DELIVER_TICKET_HOME=$S/state
R=$S/repo
[ -e "$R" ] && { echo "scratch dir already used: $S (pick a new one; the script never deletes anything)" >&2; exit 2; }
mkdir -p "$R" && cd "$R" && git init -q -b main && git commit -q --allow-empty -m init
echo '.claude/worktrees/' >> .git/info/exclude
key=$(printf '%s-%s' repo "$(printf '%s' "$R" | shasum -a 1 | cut -c1-8)")
DT=$DELIVER_TICKET_HOME; ST=$DT/$key
mkdir -p "$ST/tickets" "$ST/closed" "$ST/evidence" "$DT/sessions" "$S/src" "$S/outside"
python3 -I -c 'import json,sys; g=json.load(open(sys.argv[1])); g.update(project_key=sys.argv[3], repo_root=sys.argv[4], base_branch="main"); json.dump(g, open(sys.argv[2], "w"))' "$SK/tests/guard-json/valid.json" "$ST/guard.json" "$key" "$R"
for t in T1 T2 T3 T4 T5 T6 T7 T8 T9 T10 T11 T12 T13 T14 N1; do git worktree add -q ".claude/worktrees/$t" -b "feat-$t"; done
W() { echo "$R/.claude/worktrees/$1"; }
ticket() { printf '# %s\nstage: 3\nstate: active\n\n## Goal\ng\n\n## Plan\n%s\n\n## Build log\nlog\n' "$1" "${2:-- step 1}" > "$ST/tickets/$1.md"; }
bind() { printf 'project=%s\nticket=%s\nworktree=%s\n' "$key" "$2" "$(W "$2")" > "$DT/sessions/$1"; }
bindnw() { printf 'project=%s\nticket=%s\n' "$key" "$2" > "$DT/sessions/$1"; }        # no worktree= line: the session has not entered a worktree
sha() { "$SK/scripts/plan-hash.sh" "$1" --repo "$R" | awk '{print $3}'; }
approve() { "$SK/scripts/approve-plan.sh" "$1" --sha "$(sha "$1")" --repo "$R" --session s1 >/dev/null 2>&1; }
ticket T1; ticket T2; bind s1 T1; : > "$DT/sessions/u1"             # u1: a session with no ticket
ticket T3; printf 'x\n' > "$ST/closed/T3"                            # closed: never approved, never locked
bind s4 T4                                                           # registered by a session map only: its ticket file is "renamed away" (never created)
ticket T5 ""; bind s5 T5                                             # registered, ticket file without plan text
ticket T6; bind s6 T6; ticket T7; bind s7 T7; ticket T8; bind s8 T8; ticket T9; bind s9 T9
# the end states of `mv tickets/T10.md tickets/T10.bak` and `rm tickets/T11.md` (built directly: this test never moves or deletes anything)
printf '# T10\n\n## Plan\n- step 1\n' > "$ST/tickets/T10.bak"; bind s10 T10        # tickets/T10.md renamed to T10.bak: no ticket file under its name
bind s11 T11
ticket T12; bindnw sP T12                                              # pause test: the ticket file exists, the session has not entered a worktree
bindnw sR T13; ticket T14                                              # rebind test: T13 has NO ticket file, its worktree exists on disk, the map has no worktree= line
pass=0; fail=0
payload() { jq -nc --arg cwd "$1" --arg tool "$2" --arg cmd "$3" --arg sid "${4:-s1}" '{session_id:$sid,cwd:$cwd,hook_event_name:"PreToolUse",tool_name:$tool,tool_input:{command:$cmd}}'; }
# b <exp> <sid> <cwd> <command>   (guard.sh)       w <exp> <sid> <tool> <path>   (worktree-guard.sh)
b() { local out rc; out=$(payload "$3" Bash "$4" "$2" | "$SK/hooks/guard.sh" 2>&1); rc=$?
  [ "$rc" = "$1" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL rc=$rc want=$1 sid=$2 cwd=${3##*/} [$4]"; echo "   $out" | head -2 | cut -c1-240; }; }
w() { local out rc k=file_path; [ "$3" = NotebookEdit ] && k=notebook_path
  out=$(jq -nc --arg cwd "$R" --arg sid "$2" --arg tool "$3" --arg f "$4" --arg k "$k" '{session_id:$sid,cwd:$cwd,hook_event_name:"PreToolUse",tool_name:$tool,tool_input:{($k):$f}}' | "$SK/hooks/worktree-guard.sh" 2>&1); rc=$?
  [ "$rc" = "$1" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL wguard rc=$rc want=$1 sid=$2 $3 $4"; echo "   $out" | head -2 | cut -c1-240; }; }
W1=$(W T1); W2=$(W T2)

echo "# T1 not approved: every write route is blocked, in the ticket's session and in an unbound one; reading and the state dir are not"
for sid in s1 u1; do
  for tool in Write Edit NotebookEdit MultiEdit; do w 2 $sid $tool "$W1/src/a.ts"; done
  w 2 $sid Write "$W1/new-dir/file"
  for c in "echo x > $W1/a" "echo x >> $W1/a" "tee $W1/a" "touch $W1/a" "mkdir -p $W1/d" "cp /dev/null $W1/a" "sed -i '' s/a/b/ $W1/f" "rm $W1/f" "mv $S/outside/x $W1/x" "ln -s $S/x $W1/l" \
    "install /dev/null $W1/a" "truncate -s0 $W1/f" "dd if=/dev/null of=$W1/a" "curl -o $W1/a http://x.invalid" "git diff --output=$W1/o" "git log --output $W1/o" "git format-patch -o $W1/p HEAD" \
    "git archive -o $W1/a.tar HEAD" "git --work-tree=$W1 checkout ." "git --work-tree $W1 add ." "find $W1 -delete" "find $W1 -name x -exec rm {} ;" "find $W1 -name x -execdir sh -c x ;" \
    "find . -fprint $W1/out"; do b 2 $sid "$R" "$c"; done
  for c in "echo x > f" "cat > f <<EOF" "touch f" "git checkout -b x" "git checkout ." "git switch -c x" "git restore f" "git apply p.diff" "git am p.mbox" "git stash" "git stash pop" "git reset --hard" "git merge main" \
    "git rebase main" "git cherry-pick HEAD" "git commit -m x" "git commit --allow-empty -m x" "git add ." "git add -A && git commit -m x" "git mv a b" "git rm f" "git clean -fd" "git pull" "git revert HEAD" \
    "cd $W1 && echo x > f" "find . -delete"; do b 2 $sid "$W1" "$c"; done
  b 2 $sid "$R" "git -C $W1 commit -m x"; b 2 $sid "$R" "git -C $W1 checkout ."
  b 2 $sid "$R" "cd $W1 && touch f"
  # contents-copy forms: the source names no worktree path
  for c in "rsync -a $S/src/ $R/.claude/worktrees/" "rsync -a $S/src/ $R/.claude/" "rsync -a $S/src $R" "cp -R $S/src/. $R/.claude/" "cp -R $S/src $R/" "cp -r $S/src $R/.claude/worktrees" "cp -a $S/src/. $R/.claude/worktrees/" \
    "cp --recursive $S/src $R" "ditto $S/src $R/.claude/worktrees" "tar -C $R/.claude -xf $S/a.tar" "tar -xf $S/a.tar -C $R" "unzip $S/a.zip -d $R/.claude/worktrees" "bsdtar -x -C $R -f $S/a.tar" "pax -rw $S/src $R"; do b 2 $sid "$R" "$c"; done
  # allowed while locked: reads, git reads, the state dir, other paths
  for c in "cat $W1/f" "ls $W1" "ls -la $W1/src" "grep -rn x $W1" "git -C $W1 status" "git -C $W1 diff" "git -C $W1 log --oneline" "git -C $W1 show HEAD" "git -C $W1 branch" "find $W1 -name x" "find $W1 -name x -exec cat {} ;" \
    "find $W1 -name x -exec grep -l y {} +" "echo x > $ST/tickets/T1.md" "echo x >> $ST/tickets/T1.md" "touch $ST/tickets/new.md" "mkdir -p $ST/evidence/T1" "echo x > $ST/evidence/T1/a.txt" "cp $S/src/f $ST/evidence/T1/f" \
    "echo x > $S/outside/f" "cp -R $S/src $S/outside/" "rsync -a $S/src/ $S/outside/" "tar -C $S/outside -xf $S/a.tar" "git -C $(W N1) status"; do b 0 $sid "$R" "$c"; done
  for c in "git status" "git diff" "git log" "ls" "cat f"; do b 0 $sid "$W1" "$c"; done
  w 0 $sid Write "$ST/tickets/T1.md"; w 0 $sid Edit "$ST/tickets/T1.md"; w 0 $sid Write "$ST/evidence/T1/a.txt"; w 0 $sid Write "$S/outside/a.ts"
done
echo "## non-recursive single-file copies into the main checkout stay allowed for an unbound session, and a plain (non-ticket) worktree is not locked"
for c in "cp $S/src/f $R/f.txt" "cp $S/src/f $R/.claude/f.txt" "mv $S/outside/a $R/b.txt" "ln -s $S/x $R/l" "install /dev/null $R/f2" "echo x > $(W N1)/a" "cp -R $S/src $(W N1)/"; do b 0 u1 "$R" "$c"; done
w 0 u1 Write "$(W N1)/a.ts"
echo "## the message names the way out"
out=$(payload "$R" Bash "echo x > $W1/a" u1 | "$SK/hooks/guard.sh" 2>&1)
case "$out" in *plan-hash.sh*approve-plan.sh*) pass=$((pass+1));; *) fail=$((fail+1)); echo "FAIL message: $out";; esac

echo "# approving T1 unlocks T1 only"
approve T1 && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL approve T1"; }
for sid in s1 u1; do
  for tool in Write Edit NotebookEdit MultiEdit; do w 0 $sid $tool "$W1/src/a.ts"; done
  for c in "echo x > $W1/a" "touch $W1/a" "mkdir -p $W1/d" "tee $W1/a" "git diff --output=$W1/o"; do b 0 $sid "$R" "$c"; done
  for c in "echo x > f" "git add ." "git commit --allow-empty -m x" "git checkout -b y" "git stash"; do b 0 $sid "$W1" "$c"; done
  w 2 $sid Write "$W2/src/a.ts"; b 2 $sid "$R" "echo x > $W2/a"                        # another ticket's approval does not unlock this one
  b 2 $sid "$R" "rsync -a $S/src/ $R/.claude/worktrees/"                               # T2 is still locked: the ancestor rule still applies
done
echo "## an edit of the plan text re-locks; an edit elsewhere in the ticket file does not"
printf '# T1\nstage: 5\nstate: active\n\n## Goal\nCHANGED\n\n## Plan\n- step 1\n\n## Build log\nmore log\n' > "$ST/tickets/T1.md"
for sid in s1 u1; do w 0 $sid Write "$W1/src/a.ts"; b 0 $sid "$R" "echo x > $W1/a"; done
ticket T1 $'- step 1\n- step 2 (added after the approval)'
for sid in s1 u1; do w 2 $sid Write "$W1/src/a.ts"; b 2 $sid "$R" "echo x > $W1/a"; b 2 $sid "$W1" "git commit -m x"; done
ticket T1
for sid in s1 u1; do w 0 $sid Write "$W1/src/a.ts"; done                           # the exact old text matches the marker again
echo "## --rework closes the lock again; a new approval opens it"
approve T9
w 0 u1 Write "$(W T9)/a"
"$SK/scripts/approve-plan.sh" T9 --rework --reason "MR comments" --repo "$R" --session s1 >/dev/null 2>&1
w 2 u1 Write "$(W T9)/a"; b 2 s9 "$R" "echo x > $(W T9)/a"
approve T9; w 0 u1 Write "$(W T9)/a"

echo "# fail-closed: a registered ticket whose file or plan or marker cannot be trusted is locked"
w 2 u1 Write "$(W T4)/a"; b 2 s4 "$R" "echo x > $(W T4)/a"                         # no ticket file at all (renamed / deleted): still locked, not unlocked
w 2 u1 Write "$(W T5)/a"                                                          # no plan text
printf 'sha256=%s\n' "$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import plan_lock; print(plan_lock.plan_hash(open(sys.argv[2]).read())[0])' "$SK/scripts" "$ST/tickets/T6.md")" > "$S/outside/T6.plan"
mkdir -p "$ST/approvals"; ln -s "$S/outside/T6.plan" "$ST/approvals/T6.plan"
w 2 u1 Write "$(W T6)/a"; b 2 s6 "$R" "echo x > $(W T6)/a"                         # marker is a symlink (to a VALID marker)
printf 'garbage\n' > "$ST/approvals/T7.plan"
w 2 u1 Write "$(W T7)/a"                                                          # marker without a sha256 line
printf 'sha256=%s\n' "$(printf x | shasum -a 256 | cut -c1-64)" > "$ST/approvals/T8.plan"
w 2 u1 Write "$(W T8)/a"                                                          # marker of another plan
w 2 u1 Write "$W2/a"                                                              # T2 is registered by its ticket file alone (no session map names it)
echo "## the literal sequences (mv tickets/T10.md tickets/T10.bak, rm tickets/T11.md) leave the ticket registered by its session map, so the worktree stays locked"
for sid in u1 s10 s11; do w 2 $sid Write "$(W T10)/a"; w 2 $sid Write "$(W T11)/a"; b 2 $sid "$R" "echo x > $(W T10)/a"; b 2 $sid "$R" "touch $(W T11)/a"; b 2 $sid "$(W T10)" "git commit -m x"; done
echo "## pause and rebind keep the ticket registered (A1 was this class of bug)"
"$SK/scripts/session-map.sh" pause T12 --reason "intake stop" --session sP --repo "$R" >"$S/pause.out" 2>&1; req=$?
[ $req = 0 ] && grep -q '^ticket=T12$' "$DT/sessions/sP" && grep -q '^paused=T12$' "$DT/sessions/sP" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL pause: rc=$req"; cat "$S/pause.out" "$DT/sessions/sP"; }
w 2 u1 Write "$(W T12)/a"; w 2 sP Write "$(W T12)/a"; b 2 u1 "$R" "echo x > $(W T12)/a"           # paused: still registered, still locked
"$SK/scripts/session-map.sh" rebind T13 T14 --session sR --repo "$R" >"$S/rebind.out" 2>&1; rc=$?
[ $rc != 0 ] && grep -q '^ticket=T13$' "$DT/sessions/sR" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL rebind of a token whose worktree exists on disk must be refused: rc=$rc"; cat "$S/rebind.out" "$DT/sessions/sR"; }
w 2 u1 Write "$(W T13)/a"; w 2 sR Write "$(W T13)/a"; b 2 u1 "$R" "echo x > $(W T13)/a"           # still registered, still locked (no ticket file, no plan)
echo "## ref writes that move a locked ticket's branch without touching its files"
head=$(git -C "$R" rev-parse HEAD)
for sid in s1 u1; do
  for c in "git update-ref refs/heads/feat-T2 $head" "git update-ref feat-T2 $head" "git update-ref -m msg refs/heads/feat-T2 $head" "git update-ref --no-deref refs/heads/feat-T2 $head $head" "git update-ref -d refs/heads/feat-T2" \
    "git update-ref --stdin" "git branch -f feat-T2 $head" "git branch -fq feat-T2" "git branch --force feat-T2" "git branch -C other feat-T2" "git branch -D feat-T2" "git branch -d feat-T2" \
    "git fetch . other:feat-T2" "git fetch . +other:refs/heads/feat-T2" "git fetch --update-head-ok . other:other2" "git push . HEAD:feat-T2" "git push . HEAD:refs/heads/feat-T2" \
    "git worktree remove $W2" "git worktree remove --force $W2" "git worktree move $W2 $S/outside/moved" "cd $R/.claude/worktrees && git worktree remove T2"; do b 2 $sid "$R" "$c"; done
  for c in "git update-ref refs/heads/scratch-ref $head" "git update-ref -d refs/heads/scratch-ref" "git branch scratch2" "git branch -f scratch2 $head" "git fetch origin" "git fetch . other:scratch3" "git worktree list" "git branch --show-current" "git rev-parse refs/heads/feat-T2"; do b 0 $sid "$R" "$c"; done
done
echo "## 7z / 7za / 7zz x|e into an ancestor of a locked worktree"
for c in "7z x $S/a.7z -o$R/.claude/worktrees" "7z x -o$R $S/a.7z" "7z e $S/a.7z -o$R/.claude" "7za x $S/a.7z -o$R" "7zz x $S/a.7z -o$R/.claude/worktrees" "cd $R && 7z x $S/a.7z" "cd $R/.claude && 7z e $S/a.7z"; do for sid in s1 u1; do b 2 $sid "$R" "$c"; done; done
for c in "7z x $S/a.7z -o$S/outside" "cd $S/outside && 7z x $S/a.7z" "7z l $S/a.7z"; do b 0 u1 "$R" "$c"; done
echo "## closed tickets, other worktrees, the main checkout"
w 0 u1 Write "$(W T3)/a"; b 0 u1 "$R" "echo x > $(W T3)/a"                       # closed: not locked
w 0 u1 Write "$(W N1)/a"                                                          # not a ticket worktree at all
b 0 u1 "$R" "echo x > $R/README.md"
if [ -d "$R/.claude/worktrees/t2" ]; then echo "## case-insensitive filesystem: .../worktrees/t2 is T2's worktree"; w 2 u1 Write "$R/.claude/worktrees/t2/a"; b 2 u1 "$R" "echo x > $R/.claude/worktrees/t2/a"; fi

echo "# if the ref write got through anyway (simulated here by running it directly): the worktree is dirty and verify-record.sh refuses to record, so the push stays blocked"
python3 -I -c 'import json,sys; g=json.load(open(sys.argv[1])); g["verify"]={"lint":"true","test":None,"build":None,"on_push":["lint"],"timeout_sec":20}; json.dump(g, open(sys.argv[1],"w"))' "$ST/guard.json"
blob=$(printf hi | git -C "$R" hash-object -w --stdin); tree=$(printf '100644 blob %s\tinjected.txt\n' "$blob" | git -C "$R" mktree)
new=$(git -C "$R" commit-tree "$tree" -p "$(git -C "$R" rev-parse refs/heads/feat-T1)" -m injected)
git -C "$R" update-ref refs/heads/feat-T1 "$new"
[ -n "$(git -C "$W1" status --porcelain)" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL the worktree is not dirty after its branch moved"; }
"$SK/scripts/verify-record.sh" T1 --guard "$ST/guard.json" >"$S/vr.out" 2>&1; rc=$?
[ $rc = 2 ] && [ ! -e "$ST/evidence/T1/verify.json" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL verify-record.sh on the dirty worktree: rc=$rc"; cat "$S/vr.out"; }
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
