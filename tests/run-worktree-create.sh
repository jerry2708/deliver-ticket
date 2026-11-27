#!/bin/bash
# Dry runs of hooks/worktree-create.sh + setup-worktree.sh + env-keys.sh. Usage: tests/run-worktree-create.sh <new scratch dir>
set -u
S=${1:?new scratch dir}; SK=$(cd "$(dirname "$0")/.." && pwd)
[ "$(cd "$SK" && pwd -P)" = "$(cd "$HOME/.claude/skills/deliver-ticket" 2>/dev/null && pwd -P)" ] && echo "warning: this suite tests the LIVE checkout $SK - build and test in the dev clone (docs/plan.md, dev-copy process)" >&2
[ -e "$S" ] && { echo "scratch dir exists: $S (never deletes; pick a new one)" >&2; exit 2; }
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
export DELIVER_TICKET_HOME=$S/state; mkdir -p "$DELIVER_TICKET_HOME"
pass=0; fail=0
ok() { if [ "$1" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $2"; fi; }
mkrepo() { mkdir -p "$1" && (cd "$1" && git init -q -b main && git commit -q --allow-empty -m init && echo '.claude/worktrees/' >> .git/info/exclude); }
hook() { jq -nc --arg n "$2" --arg c "$1" '{session_id:"s",cwd:$c,hook_event_name:"WorktreeCreate",name:$n}' | "$SK/hooks/worktree-create.sh"; }

echo "# repo WITHOUT delivery state => exact default behaviour"
mkrepo $S/plain; git -C $S/plain branch -q trunk
out=$(hook $S/plain T1 2>$S/err); rc=$?
ok $rc "plain: rc"; [ "$out" = "$S/plain/.claude/worktrees/T1" ]; ok $? "plain: path printed ($out)"
[ "$(git -C $S/plain/.claude/worktrees/T1 rev-parse --abbrev-ref HEAD)" = worktree-T1 ]; ok $? "plain: branch worktree-T1"
[ -z "$(ls $DELIVER_TICKET_HOME/*/delivery.log 2>/dev/null)" ]; ok $? "plain (no delivery state): no branch record written anywhere"
out2=$(hook $S/plain T1 2>/dev/null); [ "$out2" = "$out" ]; ok $? "plain: idempotent (same path, rc 0)"
git -C $S/plain worktree list | grep -c worktrees/T1 | grep -qx 1; ok $? "plain: exactly one worktree T1"
hook $S/plain 'bad name' 2>/dev/null; [ $? != 0 ]; ok $? "plain: unsafe name rejected"
hook $S/plain '../x' 2>/dev/null; [ $? != 0 ]; ok $? "plain: ../x rejected"
hook /tmp T9 2>/dev/null; [ $? != 0 ]; ok $? "non-repo cwd: error, rc != 0"
# from inside an existing worktree the path is still rooted at the main checkout
out3=$(hook $S/plain/.claude/worktrees/T1 T2 2>/dev/null); [ "$out3" = "$S/plain/.claude/worktrees/T2" ]; ok $? "plain: cwd in a worktree still roots at main ($out3)"

echo "# repo WITH state"
R=$S/proj; mkrepo $R; echo SECRET=1 > $R/.env.local; mkdir -p $R/apps
key=$(printf '%s-%s' proj "$(printf '%s' "$R" | shasum -a 1 | cut -c1-8)"); mkdir -p $DELIVER_TICKET_HOME/$key
cat > $DELIVER_TICKET_HOME/$key/guard.json <<J
{"version":1,"project_key":"$key","repo_root":"$R","base_branch":"main","branch_naming":"feature/{id}-{slug}",
 "remotes":{"push":"mirror","allowed":["mirror"],"forbidden":["origin"]},
 "verify":{"lint":null,"test":null,"build":null,"on_push":[],"timeout_sec":30},
 "env_files":[".env.local","missing/.env","../escape/.env"],"install":"echo INSTALL-RAN > installed.txt","ports":{"vars":["PORT","AGENT_PORT"],"base":3100,"step":10}}
J
out=$(hook $R WL-01 2>$S/err); rc=$?; ok $rc "state: rc ($(cat $S/err | tr '\n' ' '))"
wt=$R/.claude/worktrees/WL-01; [ "$out" = "$wt" ]; ok $? "state: path $out"
[ "$(git -C $wt rev-parse --abbrev-ref HEAD)" = feature/WL-01 ]; ok $? "state: branch from naming rule (feature/WL-01)"
# C11: the branch record git-commit.sh / git-rename.sh trust (delivery.log, protected state); the ticket file is not used
grep -q '| session=s | ticket=WL-01 | branch | feature/WL-01$' $DELIVER_TICKET_HOME/$key/delivery.log; ok $? "state: branch recorded in delivery.log"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import git_safe; sys.exit(0 if git_safe.recorded_branch(sys.argv[2], "WL-01") == "feature/WL-01" else 1)' "$SK/scripts" $DELIVER_TICKET_HOME/$key; ok $? "state: git_safe.recorded_branch reads it"
[ -L $wt/.env.local ] && [ "$(readlink $wt/.env.local)" = "$R/.env.local" ]; ok $? "state: env file symlinked to main checkout"
[ ! -e $wt/missing ] && [ ! -e $wt/../escape ]; ok $? "state: missing / unsafe env names skipped"
grep -q INSTALL-RAN $wt/installed.txt; ok $? "state: install ran in worktree"
grep -qx 'PORT=3100' $DELIVER_TICKET_HOME/$key/ports/WL-01 && grep -qx 'AGENT_PORT=3101' $DELIVER_TICKET_HOME/$key/ports/WL-01; ok $? "state: port block slot 0 recorded"
hook $R WL-02 >/dev/null 2>&1; grep -qx 'PORT=3110' $DELIVER_TICKET_HOME/$key/ports/WL-02; ok $? "state: second ticket gets slot 1 (PORT=3110)"
out2=$(hook $R WL-01 2>/dev/null); [ "$out2" = "$wt" ] && [ "$(grep -c INSTALL-RAN $wt/installed.txt)" = 1 ]; ok $? "state: idempotent, no re-setup"
# C11i: the evidence dir exists after setup (stage 3 redirects into it); the env-link message names both causes (sandbox denyRead / missing)
[ -d $DELIVER_TICKET_HOME/$key/evidence/WL-01 ] && [ -d $DELIVER_TICKET_HOME/$key/evidence/WL-02 ]; ok $? "state: evidence/<ID>/ created for each ticket (C11i)"
grep -q 'env file missing/.env not visible - not linked (inside the sandbox: hidden by denyRead .env\*' $S/err; ok $? "state: env-link message names the sandbox denyRead ($(grep 'missing/.env' $S/err | head -c 160))"
! grep -q 'not in main checkout - not linked' $S/err; ok $? "state: old misleading env-link message gone"
git -C $R worktree add -q --detach $R/.claude/worktrees/_base main 2>/dev/null
"$SK/scripts/setup-worktree.sh" $R $R/.claude/worktrees/_base _base >/dev/null 2>$S/errb; rc=$?
[ $rc = 0 ] && [ ! -e $DELIVER_TICKET_HOME/$key/evidence/_base ] && [ ! -e $DELIVER_TICKET_HOME/$key/ports/_base ]; ok $? "_base setup: rc 0 ($rc), no evidence/_base, no port block"
# C11i: an unsafe id (stage 1b 2b calls the script directly) is refused before anything is written: nothing outside evidence/ and ports/, nothing at all
before=$(cd $DELIVER_TICKET_HOME && find . | sort)
"$SK/scripts/setup-worktree.sh" $R $wt ../x >/dev/null 2>$S/errx; rc=$?
[ $rc = 1 ] && grep -q "unsafe or empty ticket id '../x'" $S/errx && [ ! -e $DELIVER_TICKET_HOME/$key/x ] && [ "$(cd $DELIVER_TICKET_HOME && find . | sort)" = "$before" ]; ok $? "unsafe id ../x: exit 1 ($rc), nothing created in the state root"
for bad in '' '.x' 'a/b'; do "$SK/scripts/setup-worktree.sh" $R $wt "$bad" >/dev/null 2>&1; [ $? = 1 ]; ok $? "unsafe id '$bad': exit 1"; done
# failure => undo only what this run created
sed -i.bak 's#echo INSTALL-RAN > installed.txt#exit 7#' $DELIVER_TICKET_HOME/$key/guard.json
hook $R WL-03 >/dev/null 2>$S/err3; [ $? != 0 ]; ok $? "fail: install error => rc != 0 ($(head -c 120 $S/err3 | tr '\n' ' '))"
[ ! -d $R/.claude/worktrees/WL-03 ] && ! git -C $R rev-parse --verify -q feature/WL-03 >/dev/null; ok $? "fail: no half-made worktree or branch left"
[ -d $wt ] && git -C $R rev-parse --verify -q feature/WL-01 >/dev/null; ok $? "fail: earlier worktree untouched"
# remote branch clash
git -C $R remote add mirror https://example.invalid/m.git; git -C $R update-ref refs/remotes/mirror/feature/WL-04 HEAD
hook $R WL-04 >/dev/null 2>$S/err4; [ $? != 0 ] && grep -q "already exists on remote" $S/err4; ok $? "remote-branch clash => stop"
[ ! -d $R/.claude/worktrees/WL-04 ]; ok $? "remote-branch clash: nothing created"
# base missing
sed -i.bak 's#"base_branch":"main"#"base_branch":"nope"#' $DELIVER_TICKET_HOME/$key/guard.json
hook $R WL-05 >/dev/null 2>/dev/null; [ $? != 0 ]; ok $? "missing base branch => error"
# corrupt guard.json => error, not the default behaviour
echo '{bad' > $DELIVER_TICKET_HOME/$key/guard.json
hook $R WL-06 >/dev/null 2>/dev/null; [ $? != 0 ] && [ ! -d $R/.claude/worktrees/WL-06 ]; ok $? "corrupt guard.json => error, nothing created"

echo "# port block race: 6 tickets set up in parallel must get 6 distinct slots"
mkrepo $S/par; keyp=$(printf '%s-%s' par "$(printf '%s' "$S/par" | shasum -a 1 | cut -c1-8)"); mkdir -p $DELIVER_TICKET_HOME/$keyp
cat > $DELIVER_TICKET_HOME/$keyp/guard.json <<J
{"version":1,"project_key":"$keyp","repo_root":"$S/par","base_branch":"main","remotes":{"push":null,"allowed":[],"forbidden":[]},
 "verify":{"lint":null,"test":null,"build":null,"on_push":[],"timeout_sec":30},"env_files":[],"install":null,"ports":{"vars":["PORT"],"base":4000,"step":10}}
J
for i in 1 2 3 4 5 6; do hook $S/par P$i >/dev/null 2>&1 & done; wait
n=$(cat $DELIVER_TICKET_HOME/$keyp/ports/P? 2>/dev/null | grep '^PORT=' | sort -u | wc -l | tr -d ' '); [ "$n" = 6 ]; ok $? "6 parallel setups => $n distinct ports"
[ ! -d $DELIVER_TICKET_HOME/$keyp/ports/.lock ]; ok $? "lock released"
echo "# branch naming: the real pattern {type}/{id-lowercase}-{slug} (the hook knows only the ticket ID)"
mkproj() { # mkproj <dir> <naming> -> repo with state
  mkrepo $1; local k; k=$(printf '%s-%s' "$(basename $1)" "$(printf '%s' "$1" | shasum -a 1 | cut -c1-8)"); mkdir -p $DELIVER_TICKET_HOME/$k
  cat > $DELIVER_TICKET_HOME/$k/guard.json <<J
{"version":1,"project_key":"$k","repo_root":"$1","base_branch":"main","branch_naming":"$2",
 "remotes":{"push":"mirror","allowed":["mirror"],"forbidden":["origin"]},
 "verify":{"lint":null,"test":null,"build":null,"on_push":[],"timeout_sec":30},
 "env_files":[],"install":null,"ports":{"vars":[],"base":3100,"step":10}}
J
}
mkproj $S/rp '{type}/{id-lowercase}-{slug}'
out=$(hook $S/rp RETRO-7 2>$S/err); rc=$?; ok $rc "real pattern: rc ($(cat $S/err | tr '\n' ' '))"
[ "$(git -C $out rev-parse --abbrev-ref HEAD)" = "work/retro-7" ]; ok $? "real pattern: branch is exactly work/retro-7 (no {type}, no {id-lowercase}, no trailing '-')"
out=$(hook $S/rp WL-05 2>/dev/null); [ "$(git -C $out rev-parse --abbrev-ref HEAD)" = "work/wl-05" ]; ok $? "real pattern: WL-05 -> work/wl-05"
mkproj $S/rp2 '{type}/{slug}-{id}'
out=$(hook $S/rp2 RETRO-7 2>/dev/null); [ "$(git -C $out rev-parse --abbrev-ref HEAD)" = "work/RETRO-7" ]; ok $? "slug dropped in front: no '/-' left (work/RETRO-7)"
mkproj $S/rp3 'feature/{id}-{slug}'
out=$(hook $S/rp3 WL-01 2>/dev/null); [ "$(git -C $out rev-parse --abbrev-ref HEAD)" = "feature/WL-01" ]; ok $? "old default pattern still gives feature/WL-01"
mkproj $S/rp4 '{type}/{ticket}-{slug}'
hook $S/rp4 RETRO-7 2>$S/err4 >/dev/null; rc=$?; [ $rc != 0 ] && grep -q 'placeholder the hook cannot fill' $S/err4; ok $? "unknown placeholder {ticket}: refused with a clear message (rc $rc)"
[ ! -e $S/rp4/.claude/worktrees/RETRO-7 ]; ok $? "unknown placeholder: no worktree left behind"
echo "# env-keys.sh: names only"
# C11h h: the file must lie under the repo_root of the project's guard.json (strict cases: tests/run-env-keys.sh); the corrupt-guard case above broke it, so
# this section writes a valid one again
printf '{"version":1,"repo_root":"%s"}\n' "$R" > $DELIVER_TICKET_HOME/$key/guard.json
printf 'A=secretvalue1\nexport B = "two words"\n# C=commented\n  D_1=x\nbad line\nE=\n' > $R/.env.test
out=$(cd $R && "$SK/scripts/env-keys.sh" $R/.env.test --repo $R | tr '\n' ' '); [ "$out" = "A B D_1 E " ]; ok $? "env-keys: names [$out]"
(cd $R && "$SK/scripts/env-keys.sh" $R/.env.test --repo $R) | grep -q -e secretvalue -e 'two words'; [ $? != 0 ]; ok $? "env-keys: no values in output"
(cd $R && "$SK/scripts/env-keys.sh" $R/apps --repo $R 2>/dev/null); [ $? != 0 ]; ok $? "env-keys: refuses non-.env name"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
