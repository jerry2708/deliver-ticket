#!/bin/bash
# Dry runs of the hooks against a throw-away repo. Usage: tests/run-hooks.sh <scratch-dir>
# Never touches ~/.claude/settings.json or the real state dir (DELIVER_TICKET_HOME is redirected).
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
[ "$(cd "$SK" && pwd -P)" = "$(cd "$HOME/.claude/skills/deliver-ticket" 2>/dev/null && pwd -P)" ] && echo "warning: this suite tests the LIVE checkout $SK - build and test in the dev clone (docs/plan.md, dev-copy process)" >&2
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
export DELIVER_TICKET_HOME=$S/state
R=$S/repo
[ -e "$R" ] && { echo "scratch dir already used: $S (pick a new one; the script never deletes anything)" >&2; exit 2; }
mkdir -p "$R" && cd "$R" && git init -q -b main && git commit -q --allow-empty -m init
git remote add origin https://example.invalid/o.git; git remote add mirror https://example.invalid/m.git
echo '.claude/worktrees/' >> .git/info/exclude
git worktree add -q .claude/worktrees/T1 -b feat-T1
key=$(printf '%s-%s' repo "$(printf '%s' "$R" | shasum -a 1 | cut -c1-8)")
mkdir -p "$DELIVER_TICKET_HOME/$key" "$DELIVER_TICKET_HOME/sessions"
cat > "$DELIVER_TICKET_HOME/$key/guard.json" <<J
{"version":1,"project_key":"$key","repo_root":"$R","base_branch":"main",
 "remotes":{"push":"mirror","allowed":["mirror"],"forbidden":["origin"]},
 "verify":{"lint":"true","test":"false","build":null,"on_push":["lint","test"],"timeout_sec":20},
 "env_files":[".env.local"],"install":null,"ports":{"vars":[],"base":3100,"step":10},"allowlist_extra":[]}
J
# FIXTURE: "bound" now means a session with an OPEN TICKET (meaning changed 2026-11-06: before, every session in an
# initialised repo was guarded, which blocked non-ticket sessions). s1, the default session of the older tests below, is the
# ticket session of T1: its map says project + ticket, and tickets/T1.md exists. This is not there to make old tests pass:
# those tests exercise the guard of a ticket session, which must still hold.
mkdir -p "$DELIVER_TICKET_HOME/$key/tickets" "$DELIVER_TICKET_HOME/sessions"
printf 'stage: 3\nnext: read stages/3-build.md\nstate: active\nworktree: %s\n\n## Plan\n- step 1\n' "$R/.claude/worktrees/T1" > "$DELIVER_TICKET_HOME/$key/tickets/T1.md"
printf 'project=%s\nticket=T1\nworktree=%s\n' "$key" "$R/.claude/worktrees/T1" > "$DELIVER_TICKET_HOME/sessions/s1"
# C8: a ticket worktree is locked until its plan is approved (marker via the real gate script); the older tests below write T1's worktree, so T1 is approved here
"$SK/scripts/approve-plan.sh" T1 --sha "$("$SK/scripts/plan-hash.sh" T1 --repo "$R" | awk '{print $3}')" --repo "$R" --session s1 >/dev/null || { echo "fixture: approve-plan.sh failed" >&2; exit 2; }
pass=0; fail=0
payload() { jq -nc --arg cwd "$1" --arg tool "$2" --arg cmd "$3" --arg sid "${4:-s1}" --arg ev "${5:-PreToolUse}" \
  '{session_id:$sid,cwd:$cwd,hook_event_name:$ev,tool_name:$tool,tool_input:{command:$cmd}}'; }
# t <expect-rc> <hook> <cwd> <command>
t() { local exp=$1 hook=$2 cwd=$3 cmd=$4 out rc
  out=$(payload "$cwd" Bash "$cmd" | "$SK/hooks/$hook" 2>&1); rc=$?
  if [ "$rc" = "$exp" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL rc=$rc want=$exp [$hook] $cmd"; echo "   $out" | head -3; fi; }
git -C "$R" worktree add -q .claude/worktrees/T3 -b develop
W=$R/.claude/worktrees/T1
W3=$R/.claude/worktrees/T3
echo "# push variants (all must block: rc 2)"
for c in 'git push -f mirror main' 'git push --force mirror main' 'git push origin +main' 'git push --force-with-lease mirror main' \
  'git -C . push --force mirror main' 'git  push   -f  mirror' 'cd . && git push --force mirror main' 'git push origin main' \
  'git push' 'git push https://x.invalid/r.git main' 'git push mirror :old' 'git push --delete mirror old' 'git push --mirror mirror' \
  'git push mirror main --no-verify' 'git commit -n -m x' 'git commit -nm x' 'git commit --no-verify -m x' 'git -c core.hooksPath=/dev/null commit -m x' \
  'HUSKY=0 git commit -m x' 'bash -c "git push -f mirror main"' 'echo $(git push -f mirror main)' 'eval git push -f mirror' \
  '/usr/bin/env git push -f mirror main' '/usr/bin/nice git push --force mirror main' '/usr/bin/env HUSKY=0 git commit -m x' 'glab mr merge 5' 'gh pr merge 5' 'glab mr update 5 -d -' 'glab mr update 5 --description=-' 'git config alias.p "push -f"'; do t 2 guard.sh "$W" "$c"; done
echo "# push allowed through guard (rc 0)"
for c in 'git status' 'git commit -m "fix: n"' 'git commit -am msg' 'ls -la' 'npm test'; do t 0 guard.sh "$W" "$c"; done
echo "# git merge: only on a ticket branch"
t 0 guard.sh "$W" 'git merge main'
t 0 guard.sh "$W" 'git merge --no-edit main'
t 0 guard.sh "$W" 'git rebase main'
t 2 guard.sh "$W3" 'git merge feat-T1'
t 2 guard.sh "$W" 'git -C ../T3 merge feat-T1'
t 2 guard.sh "$W" 'git checkout develop && git merge feat-T1'
t 2 guard.sh "$W" 'Git checkout develop && git merge feat-T1'
t 2 guard.sh "$W" 'GIT switch develop; git merge feat-T1'
t 2 guard.sh "$W" '/usr/bin/GIT checkout develop && git merge feat-T1'
t 2 guard.sh "$W" 'git merge feat-T1 && Git checkout develop'
t 2 guard.sh "$W" 'ENV git checkout develop; git merge feat-T1'
t 0 guard.sh "$W" 'Git status && git merge main'
t 2 guard.sh "$W" 'bash -c "git switch develop; git merge feat-T1"'
t 2 guard.sh "$R" 'git merge feat-T1'
git -C "$W3" checkout -q --detach; t 2 guard.sh "$W3" 'git merge feat-T1'
echo "# .env bypasses (must block)"
for c in 'cat .env' 'cut -d= -f1 .env.example' 'grep . .env.local' 'source .env' '. .env' 'cp .env x' 'cat < .env' 'head -1 apps/web/.env.local' 'git show HEAD:.env' 'cat .e*' 'bash -c "cat .env"' 'echo $(cat .env)' 'awk 1 .env.sample' 'python3 -c "print(open(\".env\").read())"'; do t 2 guard.sh "$W" "$c"; done
echo "# .env allowed: env-keys.sh, worktree-create.sh, unrelated names"
t 0 guard.sh "$W" "$SK/scripts/env-keys.sh .env.example"
t 0 guard.sh "$W" "bash $SK/scripts/env-keys.sh .env.local"
t 0 guard.sh "$W" 'cat environment.md'
t 0 guard.sh "$W" 'ls src/env'
echo "# writes"
t 2 guard.sh "$W" 'echo DELIVER_TICKET_SELFTEST'
t 2 guard.sh "$W" 'echo x > ~/.claude/settings.json'
t 2 guard.sh "$W" 'cp x ~/.claude/settings.json'
t 2 guard.sh "$W" 'sed -i s/a/b/ ~/.claude/skills/deliver-ticket/SKILL.md'
t 2 guard.sh "$W" 'tee ~/.claude/hooks/x.sh < /dev/null'
t 2 guard.sh "$W" "echo x > $R/main-file.txt"
t 2 guard.sh "$R" 'echo x > main-file.txt'
t 2 guard.sh "$R" 'git add -A'
t 2 guard.sh "$W" 'echo x > /Users/Shared/out.txt'
t 2 guard.sh "$W" 'echo x > $SOMEVAR/out.txt'
t 2 guard.sh "$W" 'cd /etc && touch f'
t 0 guard.sh "$W" 'echo x > f.txt'
t 0 guard.sh "$W" "echo x > $DELIVER_TICKET_HOME/$key/tickets/T.md"
t 0 guard.sh "$W" 'echo x > /tmp/dt-test.txt'
t 0 guard.sh "$W" 'echo x > $TMPDIR/dt-test.txt'
t 0 guard.sh "$W" 'cat > f.txt <<EOF
hello
EOF'
t 0 guard.sh "$W" 'echo x > /dev/null 2>&1'
t 0 guard.sh "$W" 'git add -A && git commit -m "feat: x"'
t 0 guard.sh "$R" 'git status'
t 2 guard.sh "$W" 'echo "unterminated'
t 2 guard.sh "$W" 'echo $(unterminated'
echo "# malformed payload with state => block; repo without state => fast no-op"
out=$(printf 'not json' | PWD=$W "$SK/hooks/guard.sh" 2>&1); [ $? = 2 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL malformed payload did not block"; }
echo '{"cwd":"'$W'","tool_name":"Bash","tool_input":{"command":' | "$SK/hooks/guard.sh" >/dev/null 2>&1; [ $? = 2 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL truncated payload did not block"; }
printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"foo":1}}' "$W" | "$SK/hooks/guard.sh" >/dev/null 2>&1; [ $? = 2 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL missing command did not block"; }
N=$S/nostate; mkdir -p $N && (cd $N && git init -q -b main)
for h in guard verify-on-push worktree-guard session-start; do
  s=$(python3 -c 'import time;print(int(time.time()*1e9))')
  out=$(payload "$N" Bash 'git push -f origin main; cat .env' | "$SK/hooks/$h.sh" 2>&1); rc=$?
  e=$(python3 -c 'import time;print(int(time.time()*1e9))'); ms=$(( (e-s)/1000000 ))
  if [ $rc = 0 ] && [ -z "$out" ] && [ $ms -lt 500 ]; then pass=$((pass+1)); echo "ok no-state $h rc=0 ${ms}ms"; else fail=$((fail+1)); echo "FAIL no-state $h rc=$rc ${ms}ms out=$out"; fi
done
echo '{"cwd":"/tmp","tool_name":"Bash"}' | (cd /tmp && "$SK/hooks/guard.sh") >/dev/null 2>&1; [ $? = 0 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL non-git cwd should no-op"; }
echo "# verify-on-push (milestone 1c #1): the hook only READS evidence/<ID>/verify.json (written by verify-record.sh); it executes nothing"
G="$DELIVER_TICKET_HOME/$key/guard.json"
setv() { python3 -I -c 'import json,sys; p,k,v=sys.argv[1:4]; g=json.load(open(p)); g["verify"][k]=v; json.dump(g,open(p,"w"))' "$G" "$1" "$2"; }
setpush() { python3 -I -c 'import json,sys; p=sys.argv[1]; g=json.load(open(p)); g["verify"]["on_push"]=sys.argv[2:]; json.dump(g,open(p,"w"))' "$G" "$@"; }
vrec() { "$SK/scripts/verify-record.sh" "$@" >/dev/null 2>&1; echo $?; }
req() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
t 2 verify-on-push.sh "$W" 'git push mirror feat-T1'                      # no record yet: blocked, whatever the commands would do
t 0 verify-on-push.sh "$W" 'git push -n mirror feat-T1'
t 0 verify-on-push.sh "$W" 'git status'
req "$(vrec T1 --guard "$G")" 1 "record with test=false exits 1"
t 2 verify-on-push.sh "$W" 'git push mirror feat-T1'                      # the record says test failed
setv test true
t 2 verify-on-push.sh "$W" 'git push mirror feat-T1'                      # command string changed since the record: old record void
req "$(vrec T1 --guard "$G")" 0 "record with test=true exits 0"
t 0 verify-on-push.sh "$W" 'git push mirror feat-T1'
out=$(payload "$W" Bash 'git push mirror feat-T1' u1 | "$SK/hooks/verify-on-push.sh" 2>&1); req "$?" 0 "the hook does not depend on the session (unbound u1: $out)"
t 2 verify-on-push.sh "$R" 'git push mirror feat-T1'                      # no ticket resolvable from the cwd (the repo root): fail-closed
t 2 verify-on-push.sh "$R/.claude/worktrees" 'git push mirror feat-T1'
echo x > "$W/f.txt"; git -C "$W" add f.txt; git -C "$W" commit -q -m "tree changes"
t 2 verify-on-push.sh "$W" 'git push mirror feat-T1'                      # HEAD's tree changed since the record
echo y > "$W/untracked.txt"
req "$(vrec T1 --guard "$G")" 2 "verify-record refuses an unclean worktree (untracked file)"
t 2 verify-on-push.sh "$W" 'git push mirror feat-T1'                      # ... and wrote no new record
git -C "$W" add untracked.txt; git -C "$W" commit -q -m "add untracked"
req "$(vrec T1 --guard "$G")" 0 "clean worktree: record exits 0"
t 0 verify-on-push.sh "$W" 'git push mirror feat-T1'
echo "## every ref the push sends must have the recorded tree, not only HEAD"
git -C "$W" branch other-tree HEAD~1
t 0 verify-on-push.sh "$W" 'git push mirror'                              # no refspec = the current branch = HEAD
t 0 verify-on-push.sh "$W" 'git push mirror HEAD:refs/heads/x'
t 0 verify-on-push.sh "$W" 'git push -u mirror feat-T1:feat-T1'
t 2 verify-on-push.sh "$W" 'git push mirror other-tree'                   # another branch, other tree
t 2 verify-on-push.sh "$W" "git push mirror $(git -C "$W" rev-parse HEAD~1):refs/heads/x"
t 2 verify-on-push.sh "$W" 'git push mirror HEAD~1:refs/heads/x'
t 2 verify-on-push.sh "$W" 'git push mirror feat-T1 other-tree'           # one good source, one bad
t 2 verify-on-push.sh "$W" 'git push --all mirror'
t 2 verify-on-push.sh "$W" 'git push --mirror mirror'
t 2 verify-on-push.sh "$W" 'git push --tags mirror'
t 2 verify-on-push.sh "$W" 'git push mirror refs/heads/*:refs/heads/*'
t 2 verify-on-push.sh "$W" 'git push mirror no-such-ref'                  # cannot be resolved
t 2 verify-on-push.sh "$W" 'git push --delete mirror x'
git -C "$W" config push.default matching
t 2 verify-on-push.sh "$W" 'git push mirror'                              # matching = every matching branch
git -C "$W" config push.default simple
git -C "$W" config remote.mirror.push 'refs/heads/other-tree:refs/heads/o'
t 2 verify-on-push.sh "$W" 'git push mirror'                              # a configured push refspec redirects a bare push
git -C "$W" config --unset-all remote.mirror.push
t 0 verify-on-push.sh "$W" 'git push mirror'
echo "garbage" > "$DELIVER_TICKET_HOME/$key/evidence/T1/verify.json"
t 2 verify-on-push.sh "$W" 'git push mirror feat-T1'                      # unreadable record: fail-closed
req "$(vrec T1 --guard "$G")" 0 "re-record after garbage"
echo "## the hook runs nothing from the worktree (before 1c: verify.<k> ran unsandboxed, before the push prompt)"
setv lint "touch $S/hook-ran-this"
t 2 verify-on-push.sh "$W" 'git push mirror feat-T1'                      # lint string changed -> record void -> blocked
[ ! -e "$S/hook-ran-this" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL verify-on-push executed a verify command"; }
req "$(vrec T1 --guard "$G")" 0 "verify-record runs the command (the stage 4 call, sandboxed in real use)"
[ -e "$S/hook-ran-this" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL verify-record did not run the command"; }
setv lint true
setpush
t 0 verify-on-push.sh "$W" 'git push mirror feat-T1'                      # on_push [] : no record needed
setpush lint test
setv test "sleep 30"
t 2 verify-on-push.sh "$W" 'git push mirror feat-T1'                      # (state left as before: later tests expect a blocked push)
echo "# C5: git-push.sh / git-rename.sh validate their own arguments (they run unsandboxed), run git with the repo's hooks off"
git init -q --bare "$S/mirror.git"
git -C "$R" remote set-url mirror "file://$S/mirror.git"
mkdir -p "$S/hooks"; printf '#!/bin/sh\necho fired >> "%s/hook-fired-$(basename $0)"\n' "$S" > "$S/hooks/pre-push"; cp "$S/hooks/pre-push" "$S/hooks/reference-transaction"; chmod +x "$S/hooks/pre-push" "$S/hooks/reference-transaction"
git -C "$R" config core.hooksPath "$S/hooks"
hk() { cat "$S"/hook-fired-* 2>/dev/null | wc -l | tr -d ' '; }
gp() { local exp=$1; shift; local out rc; out=$(cd "$W" && "$SK/scripts/git-push.sh" "$@" 2>&1); rc=$?
  if [ "$rc" = "$exp" ] || { [ "$exp" = nz ] && [ "$rc" != 0 ]; }; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL git-push.sh rc=$rc want=$exp: $*"; echo "   $out" | head -3; fi; }
gr() { local exp=$1; shift; local out rc; out=$(cd "$W" && "$SK/scripts/git-rename.sh" "$@" 2>&1); rc=$?
  if [ "$rc" = "$exp" ] || { [ "$exp" = nz ] && [ "$rc" != 0 ]; }; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL git-rename.sh rc=$rc want=$exp: $*"; echo "   $out" | head -3; fi; }
setpush
gp 2 --receive-pack="touch $S/rp-ran" feat-T1
gp 2 -n mirror feat-T1
gp 2 mirror -f
gp 2 mirror
gp 2 mirror feat-T1 extra
gp 2 "file://$S/mirror.git" feat-T1
gp 2 "$S/mirror.git" feat-T1
gp 2 origin feat-T1
gp 2 mirror main
gp 2 mirror 'feat:T1'
gp 2 mirror '+feat-T1'
gp 2 mirror ':feat-T1'
gp 2 mirror 'feat*'
gp 2 mirror '--feat'
[ ! -e "$S/rp-ran" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL --receive-pack ran a command"; }
out=$(cd "$R" && "$SK/scripts/git-push.sh" mirror feat-T1 2>&1); [ $? = 2 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL git-push.sh from the main checkout: $out"; }
echo "## a tracked include file that sets core.sshCommand is refused; the same key in .git/config is not"
printf '[core]\n\tsshCommand = touch %s/ssh-ran\n' "$S" > "$R/inc.cfg"
git -C "$R" config include.path "$R/inc.cfg"
gp 2 mirror feat-T1
git -C "$R" config --unset include.path
git -C "$R" config url."file://$S/mirror.git".insteadOf "x://nothing"
gp 0 mirror feat-T1
git -C "$R" config --unset url."file://$S/mirror.git".insteadOf
echo "## verify record required when on_push lists keys"
setv lint true; setpush lint
gp 2 mirror feat-T1
req "$(vrec T1 --guard "$G")" 0 "record for the script push"
echo "## GIT_DIR / GIT_SSH_COMMAND in the environment do not reach git; the repo's pre-push and reference-transaction hooks do not run"
n0=$(hk); out=$(cd "$W" && GIT_DIR=/nonexistent GIT_SSH_COMMAND="touch $S/ssh-ran" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$S/hooks" "$SK/scripts/git-push.sh" mirror feat-T1 2>&1); req "$?" 0 "push with a hostile environment ($out)"
[ "$(git --git-dir="$S/mirror.git" rev-parse refs/heads/feat-T1)" = "$(git -C "$W" rev-parse HEAD)" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL the push did not land"; }
[ "$(hk)" = "$n0" ] && [ ! -e "$S/ssh-ran" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL a repo hook (or GIT_SSH_COMMAND / an include) ran under git-push.sh"; }
git -C "$W" push -q mirror HEAD:refs/heads/ctl >/dev/null 2>&1; [ "$(hk)" != "$n0" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL control: a plain git push should fire the hook in this fixture"; }
echo "## C5b: under HOME only ~/.gitconfig and ~/.config/git/** are trusted origins (the hooks protect those); another file pulled in by an include is refused"
mkdir -p "$S/fakehome/.config/git"
printf '[core]\n\tsshCommand = ssh -o BatchMode=yes\n' > "$S/fakehome/.gitconfig"
out=$(cd "$W" && HOME="$S/fakehome" "$SK/scripts/git-push.sh" mirror feat-T1 2>&1); req "$?" 0 "core.sshCommand in \$HOME/.gitconfig is trusted ($out)"
printf '[include]\n\tpath = %s/fakehome/other.cfg\n[core]\n\tsshCommand = ssh -o BatchMode=yes\n' "$S" > "$S/fakehome/.gitconfig"
printf '[credential]\n\thelper = !touch %s/cred-ran\n' "$S" > "$S/fakehome/other.cfg"
out=$(cd "$W" && HOME="$S/fakehome" "$SK/scripts/git-push.sh" mirror feat-T1 2>&1); req "$?" 2 "credential.helper from an included \$HOME file the hooks do not protect is refused"
[ ! -e "$S/cred-ran" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL the credential helper ran"; }
echo "## git-rename.sh"
gr 2 -f feat-T1 x
gr 2 feat-T1
gr 2 other-branch x
gr 2 feat-T1 main
gr 2 main x
gr 2 feat-T1 'a:b'
gr 2 feat-T1 '--x'
n0=$(hk)
gr 0 feat-T1 feat-T1b
[ "$(git -C "$W" symbolic-ref --short HEAD)" = feat-T1b ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL rename did not happen"; }
[ "$(hk)" = "$n0" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL a hook fired under git-rename.sh"; }
gr 0 feat-T1b feat-T1
git -C "$R" config --unset core.hooksPath
git -C "$R" remote set-url mirror https://example.invalid/m.git
setv lint true; setpush lint test; setv test "sleep 30"
echo "# worktree-guard (Edit/Write/NotebookEdit)"
wp() { jq -nc --arg cwd "$W" --arg tool "$1" --argjson ti "$2" --arg ev "${3:-PreToolUse}" '{session_id:"s1",cwd:$cwd,hook_event_name:$ev,tool_name:$tool,tool_input:$ti}' | "$SK/hooks/worktree-guard.sh" >/dev/null 2>&1; }
w() { wp "$2" "$3"; local rc=$?; if [ $rc = $1 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL wguard rc=$rc want=$1 $2 $3"; fi; }
w 0 Write "{\"file_path\":\"$W/src/a.ts\"}"
w 0 Write '{"file_path":"src/a.ts"}'
w 0 Edit "{\"file_path\":\"/tmp/x\"}"
w 0 NotebookEdit "{\"notebook_path\":\"$W/n.ipynb\"}"
w 2 NotebookEdit '{"cell_id":"1"}'
w 2 Write '{}'
w 2 Write "{\"file_path\":\"$R/src/a.ts\"}"
w 2 Write "{\"file_path\":\"$HOME/.claude/settings.json\"}"
w 2 Edit "{\"file_path\":\"$HOME/.claude/skills/deliver-ticket/SKILL.md\"}"
w 2 Write "{\"file_path\":\"$HOME/.claude/.deliver-ticket-selftest\"}"
w 2 Write "{\"file_path\":\"$W/.env.local\"}"
w 2 Write '{"file_path":"/Users/Shared/x"}'
w 0 Write "{\"file_path\":\"$HOME/.claude/projects/p/memory/m.md\"}"
echo "# worktree-guard PostToolUse(EnterWorktree) records session -> worktree"
jq -nc --arg cwd "$R" --arg w "$W" '{session_id:"sess-9",cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"EnterWorktree",tool_input:{name:"T1"},tool_response:{worktreePath:$w}}' | "$SK/hooks/worktree-guard.sh"; echo "rc=$?"
grep -q "worktree=$W" "$DELIVER_TICKET_HOME/sessions/sess-9" && { pass=$((pass+1)); echo "ok session map: $(tr '\n' ' ' < $DELIVER_TICKET_HOME/sessions/sess-9)"; } || { fail=$((fail+1)); echo "FAIL session map"; }
# session now allows its worktree even from the main checkout cwd
jq -nc --arg cwd "$R" --arg f "$W/z.txt" '{session_id:"sess-9",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$f}}' | "$SK/hooks/worktree-guard.sh" >/dev/null 2>&1; [ $? = 0 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL mapped worktree not allowed"; }
echo "# recursive searches that could read .env* (block unless excluded)"
mkdir -p "$W/se/with" "$W/se/clean"; printf 'K=1\n' > "$W/se/with/.env.example"; printf 'x\n' > "$W/se/with/a.txt"; printf 'x\n' > "$W/se/clean/a.txt"
git -C "$W" add -f se/with/.env.example se/with/a.txt se/clean/a.txt
for c in 'grep -r foo se' 'grep -rn foo se/with' 'grep -R foo .' 'grep --recursive foo se' 'grep -rl -e foo se' 'grep -d recurse foo se' 'grep -r foo' \
  'grep -r foo se/*' 'grep -r --include=*.txt foo se' 'grep -r --exclude-dir=node_modules foo se' 'grep -r --exclude=*.log foo se' 'egrep -rn foo se' \
  'rg --hidden foo se' 'rg -uu foo se' 'rg -. foo' 'rg --hidden -g "*.txt" foo se' 'rg --hidden foo' \
  'git grep foo' 'git -C se/with grep foo' 'git grep foo -- se' 'git grep --untracked foo' 'grep -r foo $UNKNOWNDIR' 'cd se && grep -r foo with'; do t 2 guard.sh "$W" "$c"; done
echo "# recursive searches: allowed forms (rc 0)"
for c in "grep -r --exclude='.env*' foo se" 'grep -rn --exclude=.env* foo se/with' "grep -r --exclude '.env*' foo se" 'grep -r foo se/clean' 'grep -rn foo se/clean/a.txt' \
  'grep foo se/with/a.txt' 'grep -c foo se/clean/a.txt' 'echo foo | grep foo' 'grep -rn foo se/clean se/clean' \
  'rg foo se' 'rg -l foo se/with' "rg --hidden -g '!.env*' foo se" "rg --hidden --glob=!.env* foo se" "rg -uu -g '!**/.env*' foo se" 'rg --hidden foo se/clean' \
  "git grep foo -- ':!.env*'" "git grep foo -- ':(exclude).env*'" "git grep foo -- se/clean" "git -C se/clean grep foo" 'git log --oneline'; do t 0 guard.sh "$W" "$c"; done
# the block message names the fixed command
out=$(payload "$W" Bash 'grep -r foo se' | "$SK/hooks/guard.sh" 2>&1); echo "$out" | grep -q "exclude='.env\*'" && echo "$out" | grep -q "rg --hidden -g '!.env\*'" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL search block message: $out"; }
echo "# session-start (compact)"
mkdir -p "$DELIVER_TICKET_HOME/$key/tickets"; printf 'stage: 3\nnext: read stages/3-build.md\n\n## Plan\n- step 1\n' > "$DELIVER_TICKET_HOME/$key/tickets/T1.md"
printf 'ticket=T1\n' >> "$DELIVER_TICKET_HOME/sessions/sess-9"
out=$(jq -nc --arg cwd "$W" '{session_id:"sess-9",cwd:$cwd,hook_event_name:"SessionStart",source:"compact"}' | "$SK/hooks/session-start.sh"); rc=$?
echo "$out" | jq -e '.hookSpecificOutput.additionalContext|test("ticket T1.*stage 3")' >/dev/null && [ $rc = 0 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL session-start out=$out"; }
# no ticket= line: derived from the worktree name
sed -i.bak '/^ticket=/d' "$DELIVER_TICKET_HOME/sessions/sess-9"
out=$(jq -nc --arg cwd "$W" '{session_id:"sess-9",cwd:$cwd,hook_event_name:"SessionStart",source:"compact"}' | "$SK/hooks/session-start.sh")
echo "$out" | jq -e '.hookSpecificOutput.additionalContext|test("ticket T1")' >/dev/null && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL session-start without ticket= line: $out"; }
out=$(jq -nc --arg cwd "$W" '{session_id:"nope",cwd:$cwd,source:"compact"}' | "$SK/hooks/session-start.sh"); [ -z "$out" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL session-start unknown session should be silent"; }
# no session map at all (stages 0-1): inject the only intake ticket, list several, stay silent for none
sc() { jq -nc --arg cwd "$W" '{session_id:"fresh",cwd:$cwd,hook_event_name:"SessionStart",source:"compact"}' | "$SK/hooks/session-start.sh"; }
printf 'stage: 1\nnext: read stages/1-intake.md\nstate: waiting\nworktree: none\n' > "$DELIVER_TICKET_HOME/$key/tickets/I1.md"
out=$(sc); echo "$out" | jq -e '.hookSpecificOutput.additionalContext|test("only ticket.*I1 \\(stage 1")' >/dev/null && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL intake single: $out"; }
printf 'stage: 0\nnext: read stages/0-environment.md\nstate: active\nworktree: none\n' > "$DELIVER_TICKET_HOME/$key/tickets/I2.md"
out=$(sc); echo "$out" | jq -e '.hookSpecificOutput.additionalContext|test("ask me which.*I1.*I2")' >/dev/null && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL intake several: $out"; }
printf 'stage: 1\nstate: cancelled\nworktree: none\n' > "$DELIVER_TICKET_HOME/$key/tickets/I1.md"
printf 'stage: 8\nstate: done\nworktree: none\n' > "$DELIVER_TICKET_HOME/$key/tickets/I2.md"
out=$(sc); [ -z "$out" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL intake none should be silent: $out"; }
echo "# bound (open ticket) vs unbound session: the main-checkout guard applies only to a session with an open ticket"
DT=$DELIVER_TICKET_HOME
tsid() { local exp=$1 hook=$2 sid=$3 cwd=$4 cmd=$5 out rc
  out=$(payload "$cwd" Bash "$cmd" "$sid" | "$SK/hooks/$hook" 2>&1); rc=$?
  if [ "$rc" = "$exp" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL rc=$rc want=$exp sid=$sid cwd=${cwd##*/} [$hook] $cmd"; echo "   $out" | head -2; fi; }
wsid() { local exp=$1 sid=$2 cwd=$3 tool=$4 ti=$5 rc
  jq -nc --arg cwd "$cwd" --arg tool "$tool" --argjson ti "$ti" --arg sid "$sid" '{session_id:$sid,cwd:$cwd,hook_event_name:"PreToolUse",tool_name:$tool,tool_input:$ti}' | "$SK/hooks/worktree-guard.sh" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "$exp" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL wguard rc=$rc want=$exp sid=$sid $tool $ti"; fi; }
mkdir -p "$R/docs"
echo "## unbound session u1 (no map): normal Claude Code behaviour in the main checkout"
wsid 0 u1 "$R" Write "{\"file_path\":\"$R/docs/x.md\"}"
wsid 0 u1 "$R" Edit "{\"file_path\":\"$R/docs/x.md\"}"
tsid 0 guard.sh u1 "$R" "echo hi > $R/docs/y.md"
tsid 0 guard.sh u1 "$R" "touch $R/docs/z.md"
tsid 0 guard.sh u1 "$R" "git -C $R add -A"
tsid 0 guard.sh u1 "$R" 'echo x > /Users/Shared/outside.txt'
tsid 0 guard.sh u1 "$R" 'echo x > $UNKNOWNVAR/a.txt'
echo "## bound session s1 (open ticket T1): main checkout stays read-only"
wsid 2 s1 "$R" Write "{\"file_path\":\"$R/docs/x.md\"}"
tsid 2 guard.sh s1 "$R" "echo hi > $R/docs/y.md"
tsid 2 guard.sh s1 "$R" "git -C $R add -A"
tsid 2 guard.sh s1 "$R" 'echo x > /Users/Shared/outside.txt'
wsid 0 s1 "$R" Write "{\"file_path\":\"$W/src/a.ts\"}"
echo "## two sessions in parallel in the same repo (one ticket, one not)"
wsid 0 u1 "$R" Write "{\"file_path\":\"$R/docs/p.md\"}"; wsid 2 s1 "$R" Write "{\"file_path\":\"$R/docs/p.md\"}"
wsid 0 u1 "$R" Write "{\"file_path\":\"$R/docs/p.md\"}"; wsid 2 s1 "$R" Write "{\"file_path\":\"$R/docs/p.md\"}"
echo "## what makes a session bound"
printf 'project=%s\nticket=T9\n' "$key" > "$DT/sessions/b2"                      # explicit token, no ticket file yet = new ticket at intake
wsid 2 b2 "$R" Write "{\"file_path\":\"$R/docs/x.md\"}"
printf 'project=other-00000000\nticket=T9\n' > "$DT/sessions/b3"                  # bound to a ticket of ANOTHER project: unbound here
wsid 0 b3 "$R" Write "{\"file_path\":\"$R/docs/x.md\"}"
wsid 2 sess-9 "$R" Write "{\"file_path\":\"$R/docs/x.md\"}"                       # EnterWorktree map (worktree under .claude/worktrees/T1 + tickets/T1.md)
git -C "$R" worktree add -q .claude/worktrees/T5 -b feat-T5; W5=$R/.claude/worktrees/T5
printf 'stage: 3\nstate: active\nworktree: %s\n' "$W5" > "$DT/$key/tickets/T5.md"
wsid 2 nomap "$W5" Write "{\"file_path\":\"$R/docs/x.md\"}"                       # cwd inside a ticket worktree with an open ticket file
msg=$(jq -nc --arg cwd "$W5" --arg f "$R/docs/x.md" '{session_id:"nomap",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$f}}' | "$SK/hooks/worktree-guard.sh" 2>&1)
echo "$msg" | grep -q 'only because its cwd is inside that worktree - cd out of the worktree' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL cwd-bound block message lacks the unbind hint: $msg"; }
msg=$(jq -nc --arg cwd "$R" --arg f "$R/docs/x.md" '{session_id:"s1",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$f}}' | "$SK/hooks/worktree-guard.sh" 2>&1)
echo "$msg" | grep -q 'cd out of the worktree' && { fail=$((fail+1)); echo "FAIL the cwd hint must appear only for cwd-bound sessions: $msg"; } || pass=$((pass+1))
wsid 0 nomap "$W3" Write "{\"file_path\":\"$R/docs/x.md\"}"                       # cwd in a worktree that has no ticket file: not a ticket session
echo "## closed ticket (marker written only by ticket-state.sh) and paused session"
mkdir -p "$DT/$key/closed"; printf 'x\n' > "$DT/$key/closed/T5"
wsid 0 nomap "$W5" Write "{\"file_path\":\"$R/docs/x.md\"}"                       # closed -> no longer bound
printf 'stage: 3\nstate: done\n' > "$DT/$key/tickets/T1.md.test"; mv "$DT/$key/tickets/T1.md.test" "$DT/$key/tickets/T1.md"
wsid 2 s1 "$R" Write "{\"file_path\":\"$R/docs/x.md\"}"                           # `state: done` TEXT does not unbind (only the marker does)
printf 'stage: 3\nnext: read stages/3-build.md\nstate: active\nworktree: %s\n\n## Plan\n- step 1\n' "$W" > "$DT/$key/tickets/T1.md"
printf 'project=%s\nticket=T9\npaused=T9\n' "$key" > "$DT/sessions/p1"
wsid 0 p1 "$R" Write "{\"file_path\":\"$R/docs/x.md\"}"                           # paused (DoR stop) -> not bound
bind() { jq -nc --arg cwd "$2" --arg sid "$1" --arg p "$3" '{session_id:$sid,cwd:$cwd,hook_event_name:"UserPromptSubmit",prompt:$p}' | "$SK/hooks/bind-session.sh"; }
bind p1 "$R" '/deliver-ticket T9 here is the answer'                            # next prompt for the ticket re-binds
wsid 2 p1 "$R" Write "{\"file_path\":\"$R/docs/x.md\"}"
echo "## A1: a pause does not unbind a ticket that has a worktree (T1: worktree exists, ticket file exists)"
printf 'project=%s\nticket=T1\nworktree=%s\npaused=T1\n' "$key" "$W" > "$DT/sessions/pw"
wsid 2 pw "$R" Write "{\"file_path\":\"$R/docs/x.md\"}"                          # paused, worktree on disk: main checkout still read-only
wsid 2 pw "$R" Edit "{\"file_path\":\"$R/docs/x.md\"}"
tsid 2 guard.sh pw "$R" "echo hi > $R/docs/y.md"
tsid 2 guard.sh pw "$R" 'echo x > /Users/Shared/outside.txt'
wsid 0 pw "$R" Write "{\"file_path\":\"$W/src/a.ts\"}"                          # the worktree itself stays writable
wsid 2 pw "$R" Write "{\"file_path\":\"$DT/$key/closed/T1\"}"                    # closed/ stays protected
printf 'project=%s\nticket=T1\npaused=T1\n' "$key" > "$DT/sessions/pw2"          # no worktree= line: the disk, not the map, decides
wsid 2 pw2 "$R" Write "{\"file_path\":\"$R/docs/x.md\"}"
printf 'project=other-00000000\nticket=T1\nworktree=%s\npaused=T1\n' "$W" > "$DT/sessions/pw3"
wsid 0 pw3 "$R" Write "{\"file_path\":\"$R/docs/x.md\"}"                         # a ticket of another project: unbound here, as before
wsid 0 u1 "$R" Write "{\"file_path\":\"$R/docs/x.md\"}"                           # session without a ticket: unchanged
tsid 0 guard.sh u1 "$R" "echo hi > $R/docs/y.md"
echo "## bookkeeping is protected in EVERY session (no self-unbind)"
for sid in u1 s1; do
  wsid 2 $sid "$R" Write "{\"file_path\":\"$DT/sessions/s1\"}"
  wsid 2 $sid "$R" Edit "{\"file_path\":\"$DT/sessions/$sid\"}"
  wsid 2 $sid "$R" Write "{\"file_path\":\"$DT/$key/closed/T9\"}"
  wsid 2 $sid "$R" Write "{\"file_path\":\"$DT/$key/delivery.log\"}"
  tsid 2 guard.sh $sid "$R" "echo paused=T1 >> $DT/sessions/s1"
  tsid 2 guard.sh $sid "$R" "sed -i '' s/ticket/x/ $DT/sessions/s1"
  tsid 2 guard.sh $sid "$R" "rm $DT/$key/closed/T5"
  tsid 2 guard.sh $sid "$R" "touch $DT/$key/closed/T1"
  tsid 2 guard.sh $sid "$R" "mv $DT/sessions/s1 $DT/sessions/s1.old"
  # C6: approvals/ (the plan-approval markers, C7) is protected state in every session, on every route
  wsid 2 $sid "$R" Write "{\"file_path\":\"$DT/$key/approvals/T1.plan\"}"
  wsid 2 $sid "$R" Edit "{\"file_path\":\"$DT/$key/approvals/T1.plan\"}"
  for c in "echo x > $DT/$key/approvals/T1.plan" "echo x >> $DT/$key/approvals/T1.plan" "touch $DT/$key/approvals/T1.plan" "tee $DT/$key/approvals/T1.plan" "cp /dev/null $DT/$key/approvals/T1.plan" \
    "mkdir $DT/$key/approvals" "rm $DT/$key/approvals/T1.plan" "rm -r $DT/$key/approvals" "mv $DT/$key/approvals $DT/$key/approvals.old" "mv $DT/$key/x $DT/$key/approvals" \
    "rm $DT/*/approvals/*" "rm -rf $DT/$key/appr*" "cd $DT/$key && echo x > approvals/T1.plan" "ln $DT/$key/approvals/T1.plan $S/hl"; do tsid 2 guard.sh $sid "$R" "$c"; done
  # symlinks: ln is a write to its destination, so a link planted AT approvals/ (redirecting later writes) or AT a marker is blocked; a link FROM approvals/ is a hard-link/read question
  for c in "ln -s $S $DT/$key/approvals" "ln -sf $S $DT/$key/approvals" "ln -s $S/x $DT/$key/approvals/T1.plan" "ln -sfn $S $DT/$key/approvals" "cd $DT/$key && ln -s $S approvals" \
    "cd $DT/$key && ln -s $S/x approvals/T1.plan" "ln $S/x $DT/$key/approvals/T1.plan" "mv $S/link $DT/$key/approvals" \
    "ln -s -t $DT/$key $S/x/approvals" "ln -s $S/x/approvals $DT/$key/" "ln -s $S/x/approvals $DT/$key" "cp -R $S/x/approvals $DT/$key/" "cp -R $S/x/approvals $DT/$key" \
    "mv $S/x/approvals $DT/$key/" "rsync -a $S/x/approvals $DT/$key/" "tar -C $DT/$key -xf $S/x/a.tar" "tar -xf $S/x/a.tar -C $DT/$key" "tar xf $S/x/a.tar -C $DT/$key" \
    "tar --directory=$DT/$key -xf $S/x/a.tar" "unzip $S/x/a.zip -d $DT/$key" "cd $DT/$key && tar -xf $S/x/a.tar" "cd $DT/$key && cp -R $S/x/approvals ." "cp -R $S/x/approvals $DT/" \
    "ln -s $S/x/sessions $DT" \
    "ditto $S/x/approvals $DT/$key/approvals" "ditto $S/x/approvals $DT/$key" "ditto -x -k $S/x/a.zip $DT/$key" "ditto $S/x $DT" "ditto -V $S/x/approvals $DT/$key/" \
    "bsdtar -x -C $DT/$key -f $S/x/a.tar" "bsdtar -xf $S/x/a.tar -C $DT/$key" "bsdtar xf $S/x/a.tar --directory $DT/$key" "gtar -C $DT/$key -xf $S/x/a.tar" \
    "cd $DT/$key && pax -r -f $S/x/a.pax" "cd $DT/$key && pax -rw $S/x/approvals ." "pax -rw $S/x/approvals $DT/$key" "cd $DT && pax -r -f $S/x/a.pax" \
    "cd $DT/$key && cpio -id < $S/x/a.cpio" "cd $DT/$key && cpio -i < $S/x/a.cpio" "cd $DT && cpio -idm < $S/x/a.cpio" "echo f | cpio -pd $DT/$key" "cd $S/x && echo f | cpio -pdm $DT/$key/" \
    "7z x $S/x/a.7z -o$DT/$key" "7z x -o$DT/$key $S/x/a.7z" "7za x $S/x/a.7z -o$DT" "cd $DT/$key && 7z x $S/x/a.7z" "cd $DT/$key && 7zz e $S/x/a.7z" \
    "git clone $S/x/src $DT/$key/approvals" "git clone $S/x/src $DT/x" "git clone $S/x/src $DT/$key" "git clone $S/x/src $DT/$key/closed" "git init $DT/x" "git worktree add $DT/x"; do tsid 2 guard.sh $sid "$R" "$c"; done
  mkdir -p "$S/x/approvals"
  for c in "ditto $S/x $S/y" "bsdtar -x -C $S/x -f $S/x/a.tar" "cd $S/x && pax -r -f $S/x/a.pax" "cd $S/x && cpio -id < $S/x/a.cpio" "echo f | cpio -pd $S/y" "7z x $S/x/a.7z -o$S/y" "cd $S/x && 7z x $S/x/a.7z" \
    "git clone $S/x/src $S/y" "git status" "ditto -c -k $S/x $S/x/a.zip" "cpio -o < $S/x/list > $S/x/a.cpio" "pax -w $S/x > $S/x/a.pax"; do tsid 0 guard.sh $sid "$R" "$c"; done
  for c in "cp $S/x/f $DT/$key/guard.candidate.json" "cp $S/x/f $DT/$key/tickets/T1.md" "tar -C $S/x -xf $S/x/a.tar" "ln -s $S/x/f $S/x/g" "cp -R $S/x/approvals $S/y"; do tsid 0 guard.sh $sid "$R" "$c"; done
  tsid 0 guard.sh $sid "$R" "cat $DT/$key/approvals/T1.plan"                     # reads stay allowed
  tsid 0 guard.sh $sid "$R" "ls $DT/$key/approvals"
done
echo "## C6: approvals/ in a directory without delivery state (nostate mode shares protected_state)"
wsid 0 s1 "$R" Write "{\"file_path\":\"$DT/$key/tickets/T1.md\"}"                 # ticket files stay writable
wsid 0 u1 "$R" Write "{\"file_path\":\"$DT/$key/tickets/T1.md\"}"
tsid 0 guard.sh s1 "$R" "$SK/scripts/session-map.sh show T1 --session s1 --repo $R"   # the skill's own scripts may write them
echo "## always-on rules also hold in an unbound session"
mkdir -p "$R/sr"; printf 'K=1\n' > "$R/sr/.env.example"
wsid 2 u1 "$R" Write "{\"file_path\":\"$R/.env.local\"}"
wsid 2 u1 "$R" Write "{\"file_path\":\"$HOME/.claude/settings.json\"}"
for c in 'cat .env.local' 'git push -f mirror main' 'git push origin main' 'git push' 'git commit --no-verify -m x' 'git -c core.hooksPath=/dev/null commit -m x' \
  'git merge feat-T1' 'glab mr merge 5' 'grep -r foo sr' 'echo DELIVER_TICKET_SELFTEST'; do tsid 2 guard.sh u1 "$R" "$c"; done
tsid 2 verify-on-push.sh u1 "$W" 'git push mirror feat-T1'
echo "## bind hook (UserPromptSubmit): maps /deliver-ticket <token> to the session"
nostate=$S/nostate; mkdir -p "$nostate" && git -C "$nostate" init -q -b main
bind nb1 "$R" '/deliver-ticket WL-05 add a wishlist thing'; grep -qx 'ticket=WL-05' "$DT/sessions/nb1" && grep -qx "project=$key" "$DT/sessions/nb1" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL bind: map for WL-05"; }
bind nb1 "$R" '/deliver-ticket WL-05 again'; [ "$(grep -c '^ticket=WL-05$' "$DT/sessions/nb1")" = 1 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL bind: duplicate line"; }
bind nb1 "$R" '/deliver-ticket RETRO-7 other'; [ "$(grep -c '^ticket=' "$DT/sessions/nb1")" = 2 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL bind: second ticket"; }
bind nb2 "$R" '/deliver-ticket init'; [ ! -e "$DT/sessions/nb2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL bind: init must bind nothing"; }
bind nb3 "$R" 'please look at /deliver-ticket docs'; [ ! -e "$DT/sessions/nb3" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL bind: ordinary prompt"; }
bind nb4 "$R" '/deliver-ticket ./tickets/WL-07.md'; grep -qx 'ticket=WL-07' "$DT/sessions/nb4" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL bind: file path -> basename"; }
bind nb5 "$R" '/deliver-ticket "T-8" quoted'; grep -qx 'ticket=T-8' "$DT/sessions/nb5" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL bind: quoted token"; }
bind nb6 "$R" '/deliver-ticket --weird'; [ ! -e "$DT/sessions/nb6" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL bind: unsafe token"; }
bind nb7 "$nostate" '/deliver-ticket T1'; [ ! -e "$DT/sessions/nb7" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL bind: repo without state must be a no-op"; }
printf 'project=other-00000000\nticket=Z1\n' > "$DT/sessions/nb8"; bind nb8 "$R" '/deliver-ticket T2 x'; grep -q 'Z1' "$DT/sessions/nb8" && { fail=$((fail+1)); echo "FAIL bind: stale project lines kept"; } || pass=$((pass+1))
bind nb10 "$R" "$(printf '<command-message>deliver-ticket</command-message>\n<command-name>/deliver-ticket</command-name>\n<command-args>RETRO-9 pasted text</command-args>')"
grep -qx 'ticket=RETRO-9' "$DT/sessions/nb10" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL bind: expanded command form"; }
out=$(bind nb9 "$R" '/deliver-ticket T2'; echo "rc=$?"); [ "$out" = "rc=0" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL bind must print nothing and exit 0: $out"; }
echo '{not json' | "$SK/hooks/bind-session.sh"; [ $? = 0 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL bind: malformed payload must not block the prompt"; }
echo "# S1: gated commands only in the spelling their ask rule matches (git push, gh / glab writes); a bound and an unbound session"
for sid in s1 u1; do
  for c in 'git -C . push mirror feat-T1' '/usr/bin/git push mirror feat-T1' 'env git push mirror feat-T1' '/usr/bin/env git push mirror feat-T1' 'FOO=1 git push mirror feat-T1' \
    'command git push mirror feat-T1' 'git -c user.name=x push mirror feat-T1' 'git --git-dir=.git push mirror feat-T1' 'git --no-pager push mirror feat-T1' \
    'bash -c "git push mirror feat-T1"' "sh -c 'git push mirror feat-T1'" 'echo $(git push mirror feat-T1)' 'eval "git push mirror feat-T1"' 'echo mirror | xargs git push' \
    'nohup git push mirror feat-T1' 'time git push mirror feat-T1' 'cd . && FOO=1 git push mirror feat-T1' \
    'gh pr --repo o/r edit 1' 'glab mr --repo o/r update 1' 'FOO=1 gh pr edit 1' 'GH_REPO=o/r gh pr edit 1' 'command gh pr edit 1' '/usr/bin/gh pr edit 1' 'gh --hostname h.example pr edit 1' \
    'gh --repo=o/r pr edit 1' 'bash -c "gh pr edit 1"' 'FOO=1 gh pr create -t x' 'gh pr -t x create' '/usr/bin/gh api /x' 'env glab api /x' 'gh --hostname h api /x' 'FOO=1 glab mr note 1' \
    'gh pr -t x reopen 1'; do tsid 2 guard.sh $sid "$W" "$c"; done
  for c in 'FOO=1 gh alias set x y' '/usr/bin/gh extension install x' 'gh pr --repo o/r checkout 5' 'env glab mr delete 1' 'FOO=1 gh issue create -t x' 'glab --hostname h alias set x y' 'GH config set k v' 'bash -c "glab token create"' 'FOO=1 gh codespace delete' 'gh pr -t x lock 1' 'FOO=1 glab snippet create'; do tsid 2 guard.sh $sid "$W" "$c"; done
  for c in 'gh alias set x y' 'gh extension install x' 'gh pr checkout 5' 'glab mr delete 1' 'gh issue create -t x' 'gh -R o/r issue view 1' 'glab alias list' 'gh config get k' 'gh codespace list' 'gh pr ready 1' 'glab snippet list' 'gh status' 'gh browse'; do tsid 0 guard.sh $sid "$W" "$c"; done
  for c in 'git status' 'git -C . status' 'FOO=1 git status' \
    'gh pr edit 1' 'gh pr create -t x' 'gh pr comment 1 -b x' 'gh -R o/r pr edit 1' 'gh --repo o/r pr edit 1' 'glab -R o/r mr update 1' 'glab mr note 1' 'gh api /x' 'glab api /x' 'gh auth status' \
    'glab release --repo o/r create x' 'gh pr list --search review' 'gh pr list --search edit' 'gh pr list --search create' 'glab mr list --search close' 'glab mr view 1 --comments' 'gh pr view 1 --json comments' 'gh pr view 1' 'gh pr list' 'gh pr --repo o/r view 1' 'gh --hostname h pr view 1' 'FOO=1 gh pr view 1' 'glab mr view 1' 'glab mr list' 'echo gh pr edit'; do tsid 0 guard.sh $sid "$W" "$c"; done
done
echo "# C5: Claude never runs git push / git branch -m itself (the repo's hooks would run unsandboxed): only git-push.sh / git-rename.sh"
for sid in s1 u1; do
  for c in 'git push mirror feat-T1' 'git push -u mirror feat-T1' 'git push -n mirror feat-T1' 'cd . && git push mirror feat-T1' 'git branch -m a b' 'git branch -M a b' 'git branch --move a b' 'git branch -fm a b' 'cd . && git branch -m a b'; do tsid 2 guard.sh $sid "$W" "$c"; done
  for c in 'git branch' 'git branch -a' 'git branch --show-current' 'git branch -d x' ; do tsid 0 guard.sh $sid "$W" "$c"; done
  tsid 0 guard.sh $sid "$W" "$SK/scripts/git-push.sh mirror feat-T1"
  tsid 0 guard.sh $sid "$W" "$SK/scripts/git-rename.sh work/t1 feat/t1"
  for c in "bash $SK/scripts/git-push.sh mirror feat-T1" "python3 $SK/scripts/git_push.py mirror feat-T1" "FOO=1 $SK/scripts/git-push.sh mirror feat-T1" "env $SK/scripts/git-push.sh mirror feat-T1" "cd . && python3 -I $SK/scripts/git_push.py mirror x"; do tsid 2 guard.sh $sid "$W" "$c"; done
done
echo "# C5b: the user's git config (~/.gitconfig, ~/.config/git/**, \$XDG_CONFIG_HOME/git/**) is not written by Claude: git-push.sh trusts it and runs unsandboxed"
for sid in s1 u1; do
  for c in 'echo x >> ~/.gitconfig' 'echo x > ~/.config/git/config' 'echo x >> ~/.config/git/ignore' 'touch ~/.gitconfig' 'tee ~/.gitconfig' 'cp /dev/null ~/.config/git/config' \
    "echo x >> $HOME/.gitconfig" 'git config --global core.sshCommand "touch /x"' 'git config --global --add credential.helper x' 'git config --system core.hooksPath /x' \
    'git config --global --unset user.name' 'git config --global -e' 'git config --global --edit' 'git config --file ~/.gitconfig core.sshCommand x' 'git config -f ~/.config/git/config a.b c' \
    'git config --global user.name x' 'git config --global --replace-all user.name x' 'git config --global set user.name x' 'git config --file="$HOME/.gitconfig" a.b c'; do tsid 2 guard.sh $sid "$W" "$c"; done
  for c in 'git config --global --get user.name' 'git config --global user.name' 'git config --global --list' 'git config --global --show-origin --get-regexp core' 'git config --system --list' \
    'git config --get remote.mirror.url' 'git config user.name' 'git config --file .git/config --list' 'cat ~/.gitconfig' 'ls ~/.config/git' "echo x > $S/.gitconfig"; do tsid 0 guard.sh $sid "$W" "$c"; done
done
out=$(jq -nc --arg cwd "$W" --arg f "$HOME/.gitconfig" '{session_id:"s1",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$f,content:"x"}}' | "$SK/hooks/worktree-guard.sh" 2>&1); req "$?" 2 "Write on ~/.gitconfig ($out)"
out=$(jq -nc --arg cwd "$W" --arg f "$HOME/.config/git/config" '{session_id:"u1",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$f,old_string:"a",new_string:"b"}}' | "$SK/hooks/worktree-guard.sh" 2>&1); req "$?" 2 "Edit on ~/.config/git/config ($out)"
out=$(XDG_CONFIG_HOME="$S/xdg" jq -nc --arg cwd "$W" --arg f "$S/xdg/git/config" '{session_id:"s1",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$f,content:"x"}}' | XDG_CONFIG_HOME="$S/xdg" "$SK/hooks/worktree-guard.sh" 2>&1); req "$?" 2 "Write on \$XDG_CONFIG_HOME/git/config ($out)"
echo "# C9a: ssh config, .netrc and the gh / glab configs join the protected group; <root>/starts/ is protected state"
for sid in s1 u1; do
  for c in 'echo x >> ~/.ssh/config' 'echo x > ~/.ssh/config.local' 'tee ~/.ssh/config' 'cp /dev/null ~/.ssh/config' 'echo x >> ~/.netrc' 'echo x > ~/.config/gh/config.yml' 'echo x >> ~/.config/gh/hosts.yml' \
    'echo x > ~/.config/glab-cli/config.yml' 'touch ~/.config/glab-cli/aliases.yml' 'git config --file ~/.config/gh/config.yml a.b c' "echo x > $DT/starts/rec9" "touch $DT/starts/rec9" "rm $DT/starts/rec9" "rm -rf $DT/starts" \
    "mv $DT/starts $DT/starts.old" "cp -R $S/x/approvals $DT/starts" "ln -s $S/x $DT/starts" "rm $DT/starts/*" "tee $DT/starts/rec9"; do tsid 2 guard.sh $sid "$W" "$c"; done
  for c in 'cat ~/.ssh/config' 'ls ~/.config/gh' 'cat ~/.netrc' "cat $DT/starts/rec1" "ls $DT/starts"; do tsid 0 guard.sh $sid "$W" "$c"; done
done
tsid 0 guard.sh u1 "$R" 'echo x >> ~/.sshx/known_hosts'; tsid 0 guard.sh u1 "$R" 'echo x > ~/.config/other-tool/config'
# C9b: ~/.ssh/** (was ~/.ssh/config*): Include targets, config.d, keys, known_hosts
for sid in s1 u1; do for c in 'echo x >> ~/.ssh/known_hosts' 'echo x > ~/.ssh/config.d/x' 'touch ~/.ssh/id_x' 'cp /dev/null ~/.ssh/authorized_keys'; do tsid 2 guard.sh $sid "$W" "$c"; done; done
for tool in Write Edit; do wsid 2 s1 "$W" $tool "{\"file_path\":\"$HOME/.ssh/config\"}"; wsid 2 u1 "$W" $tool "{\"file_path\":\"$HOME/.netrc\"}"; wsid 2 u1 "$W" $tool "{\"file_path\":\"$DT/starts/rec1\"}"; done
echo "# C9a: session-record.sh writes <root>/starts/<session_id> once (first record wins), never blocks, ignores a bad id / cwd / planted link"
sr() { jq -nc --arg sid "$1" --arg cwd "$2" --arg src "${3:-startup}" '{session_id:$sid,cwd:$cwd,hook_event_name:"SessionStart",source:$src}' | env "${@:4}" "$SK/hooks/session-record.sh" >"$S/sr.out" 2>&1; echo $?; }
SRD=$S/srroot; mkdir -p "$S/start-a" "$S/start-b" "$S/elsewhere"; ln -s "$S/start-a" "$S/start-lnk"
req "$(sr rec1 "$S/start-a" startup DELIVER_TICKET_HOME=$SRD)" 0 "session-record exits 0"
req "$(cat "$SRD/starts/rec1")" "$S/start-a" "the record is the start directory"
req "$(sr rec1 "$S/start-b" resume DELIVER_TICKET_HOME=$SRD)" 0 "resume exits 0"
req "$(cat "$SRD/starts/rec1")" "$S/start-a" "resume does not change the record (first record wins)"
req "$(sr rec1 "$S/start-b" clear DELIVER_TICKET_HOME=$SRD)" 0 "second start exits 0"
req "$(cat "$SRD/starts/rec1")" "$S/start-a" "a second SessionStart of the same id does not change it"
req "$(sr rec2 "$S/start-lnk" startup DELIVER_TICKET_HOME=$SRD)" 0 "symlinked cwd"
req "$(cat "$SRD/starts/rec2")" "$S/start-a" "the record is the physical path"
n=$(ls "$SRD/starts" | wc -l | tr -d ' ')
for bad in "" "../x" ".hid" "a b" 'a/b' 'a;b'; do sr "$bad" "$S/start-a" startup DELIVER_TICKET_HOME=$SRD >/dev/null; done
req "$(ls "$SRD/starts" | wc -l | tr -d ' ')" "$n" "a bad session id writes nothing"
sr rec3 "$S/no-such-dir" startup DELIVER_TICKET_HOME=$SRD >/dev/null; [ ! -e "$SRD/starts/rec3" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL a missing cwd wrote a record"; }
ln -s "$S/elsewhere/planted" "$SRD/starts/rec4"
req "$(sr rec4 "$S/start-a" startup DELIVER_TICKET_HOME=$SRD)" 0 "planted symlink at the record: exits 0"
[ ! -e "$S/elsewhere/planted" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL the record was written through a planted symlink"; }
mkdir -p "$S/srroot2"; ln -s "$S/elsewhere" "$S/srroot2/starts"
req "$(sr rec5 "$S/start-a" startup DELIVER_TICKET_HOME=$S/srroot2)" 0 "starts/ is a symlink: exits 0"
[ -z "$(ls -A "$S/elsewhere")" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL the record went through a symlinked starts/"; ls -A "$S/elsewhere"; }
printf '{"hook_event_name":"SessionStart"' | DELIVER_TICKET_HOME=$SRD "$SK/hooks/session-record.sh"; req "$?" 0 "garbage payload exits 0"
python3 - "$SK/hooks" "$SK/scripts" <<'PY' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL S1 unit: analyze prefix / nested, GATED_CLI vs CLI_ASK"; }
import os, sys
sys.path.insert(0, sys.argv[1]); sys.path.insert(0, sys.argv[2]); os.environ["DT_SETTINGS"] = "/nonexistent"
import dtcore, install_hooks as ih
c = dtcore.analyze("FOO=1 /usr/bin/env git push mirror x", "/tmp")[0]
assert c.argv[0] == "git" and c.prefix == ["/usr/bin/env"] and c.assigns == ["FOO=1"] and not c.nested, (c.argv, c.prefix, c.assigns)
assert not dtcore.analyze("git push mirror x", "/tmp")[0].prefix
n = [x for x in dtcore.analyze('bash -c "git push mirror x"', "/tmp") if x.argv[:2] == ["git", "push"]]
assert n and all(x.nested for x in n)
assert [x for x in dtcore.analyze("echo $(git push mirror x)", "/tmp") if x.argv[:2] == ["git", "push"]][0].nested
# the hook's list and the installed ask rules say the same (create is a user-level rule, merge is denied)
ask = {tuple(r[len("Bash("):-len(" *)")].split()) for r in ["Bash(%s)" % x for x in ih.CLI_ASK]}
hook = {(p,) + pat for p, pats in dtcore.GATED_CLI.items() for pat in pats if pat[-1] != "create"}
ask = {t for t in ask if t[1:] not in (("-R",), ("--repo",))}
assert ask == hook, (ask ^ hook)
PY
echo "# C2: .env* names in another case (.ENV is .env on a case-insensitive filesystem): blocked in a ticket session and in an unbound one"
mkdir -p "$R/sr2" "$R/apps/web"; printf 'K=1\n' > "$R/sr2/.ENV.LOCAL"
for sid in s1 u1; do
  for c in 'cat .ENV' 'cat .Env.Local' 'cat .ENV.example' 'cut -d= -f1 .Env.Local' 'grep . .ENV' 'grep -c K .ENV.LOCAL' 'source .ENV' '. .ENV' 'cat < .ENV' 'head -1 apps/web/.ENV.LOCAL' \
    'cp .ENV x' 'cp x .ENV' 'cp .Env.Local /tmp/zz-c2' 'mv .ENV /tmp/zz-c2' 'git show HEAD:.ENV' 'git show HEAD:apps/web/.Env.Local' 'awk 1 .ENV.sample' 'bash -c "cat .ENV"' 'echo $(cat .ENV)' \
    'python3 -c "print(open(\".ENV\").read())"' 'node -e "require(\"fs\").readFileSync(\".Env.Local\")"' 'cat .[eE]nv' 'grep -r K sr2' 'rg --hidden K sr2'; do tsid 2 guard.sh $sid "$R" "$c"; done
  wsid 2 $sid "$R" Write "{\"file_path\":\"$R/.ENV\"}"; wsid 2 $sid "$R" Edit "{\"file_path\":\"$R/apps/web/.Env.Local\"}"
  wsid 2 $sid "$R" NotebookEdit "{\"notebook_path\":\"$R/.ENV.LOCAL\"}"; wsid 2 $sid "$R" MultiEdit "{\"file_path\":\"$R/.Env.Production\"}"
  echo "## $sid: names that are not env files stay allowed"
  for c in 'cat env.txt' 'cat ENV.md' 'cat README.ENV.md' 'ls -la' 'grep -r foo docs'; do tsid 0 guard.sh $sid "$R" "$c"; done
  wsid 0 $sid "$R" Write "{\"file_path\":\"$W/src/ENV.md\"}"
done
echo "## C2b: grep --exclude / rg -g / git pathspec excludes are case-sensitive (probed: '.foo*' still reads .FOO.LOCAL), so an exclude of .env* must not wave a .ENV* file through"
mkdir -p "$R/sr3"; printf 'K=1\n' > "$R/sr3/.env.local"; git -C "$R" add sr2/.ENV.LOCAL sr3/.env.local
for sid in s1 u1; do
  for c in "grep -r --exclude='.env*' K sr2" "grep -r --exclude=.env\\* K sr2" "grep -rn --exclude '.env*' K ." "rg --hidden -g '!.env*' K sr2" "rg -u -u --glob '!.env*' K sr2" \
    "git grep -n K -- sr2 ':!.env*'" "git grep -n --untracked K -- sr2 ':!.env*'" "git grep -n K -- ':!.env*'"; do tsid 2 guard.sh $sid "$R" "$c"; done
  for c in "grep -r --exclude='.env*' K sr3" "rg --hidden -g '!.env*' K sr3" "git grep -n K -- sr3 ':!.env*'" "grep -r --exclude='.[eE][nN][vV]*' K sr2" "rg --hidden --iglob '!.env*' K sr2" \
    "rg --hidden -g '!.[eE][nN][vV]*' K sr2"; do tsid 0 guard.sh $sid "$R" "$c"; done
done
python3 - "$SK/hooks" <<'PY' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL C2 unit: is_env_name"; }
import sys; sys.path.insert(0, sys.argv[1]); import dtcore
f = dtcore.is_env_name
for w in (".env", ".ENV", ".Env.Local", ".ENV.example", "a/b/.Env", "HEAD:.ENV", "x=.ENV", ".[eE]nv", ".?nv"):
    assert f(w), w
for w in ("env", "ENV.md", "env.txt", "README.ENV.md", "e.nv"):
    assert not f(w), w
PY
echo "# A2: protected paths are checked in a repo / dir WITHOUT delivery state (prefilter on the state root's name, then core mode nostate)"
DT=$DELIVER_TICKET_HOME; X=$S/nongit; mkdir -p "$X" "$S/fakehome/.local/share/deliver-ticket/k/closed" "$S/real-root/k/closed" "$S/custom/dtstate/k/closed"
ln -s "$S/real-root" "$S/link-root"
printf 'project=other-00000000\nticket=T1\n' > "$DT/sessions/tk"          # a session with an open ticket (of another project), cwd in a no-state dir
PC=$DT/$key/closed/T1; PS=$DT/sessions/zz; PL=$DT/$key/delivery.log
NSSID=nsu
# nsr <expect-rc> <hook> <cwd> <tool> <path-or-command> [env args...]
nsr() { local exp=$1 hook=$2 cwd=$3 tool=$4 arg=$5 pl rc kf=file_path; shift 5
  case "$tool" in
    Bash) pl=$(payload "$cwd" Bash "$arg" "$NSSID") ;;
    *) [ "$tool" = NotebookEdit ] && kf=notebook_path
       pl=$(jq -nc --arg cwd "$cwd" --arg tool "$tool" --arg f "$arg" --arg k "$kf" --arg sid "$NSSID" '{session_id:$sid,cwd:$cwd,hook_event_name:"PreToolUse",tool_name:$tool,tool_input:{($k):$f}}') ;;
  esac
  printf '%s' "$pl" | env "$@" "$SK/hooks/$hook" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "$exp" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL nostate rc=$rc want=$exp sid=$NSSID cwd=${cwd##*/} $tool $arg $*"; fi; }
for NSSID in nsu tk; do                                       # nsu: no open ticket; tk: an open ticket in the map
  for cwd in "$nostate" "$X"; do
    for p in "$PC" "$PS" "$PL"; do
      for tool in Write Edit NotebookEdit MultiEdit; do nsr 2 worktree-guard.sh "$cwd" $tool "$p"; done
      for c in "echo x > $p" "echo x >> $p" "tee $p" "cp /dev/null $p" "sed -i '' s/a/b/ $p" "touch $p"; do nsr 2 guard.sh "$cwd" Bash "$c"; done
    done
    echo "## $NSSID / ${cwd##*/}: unprotected targets and reads stay allowed (rc 0), also when they name the state root"
    nsr 0 worktree-guard.sh "$cwd" Write "$DT/lessons.md"
    nsr 0 worktree-guard.sh "$cwd" Write "$cwd/a.txt"
    nsr 0 guard.sh "$cwd" Bash "echo x > $cwd/b.txt"
    nsr 0 guard.sh "$cwd" Bash "echo x > /tmp/zz-a2"
    nsr 0 guard.sh "$cwd" Bash "echo $DT"
    nsr 0 guard.sh "$cwd" Bash "cat $PC"
    nsr 0 guard.sh "$cwd" Bash "python3 $SK/scripts/validate-guard.py $DT/$key/guard.json"       # a skill script naming the root
  done
done
NSSID=nsu
echo "## custom root (not under HOME, not the default name), symlinked root, physical path of a symlinked root"
nsr 2 worktree-guard.sh "$nostate" Write "$S/custom/dtstate/k/closed/T1" DELIVER_TICKET_HOME=$S/custom/dtstate
nsr 2 guard.sh "$nostate" Bash "echo x > $S/custom/dtstate/k/closed/T1" DELIVER_TICKET_HOME=$S/custom/dtstate
nsr 2 guard.sh "$nostate" Bash "echo x > $S/custom/dtstate/k/approvals/T1.plan" DELIVER_TICKET_HOME=$S/custom/dtstate
nsr 2 guard.sh "$nostate" Bash "echo x > $S/custom/dtstate/starts/rec1" DELIVER_TICKET_HOME=$S/custom/dtstate
nsr 2 worktree-guard.sh "$nostate" Write "$S/custom/dtstate/starts/rec1" DELIVER_TICKET_HOME=$S/custom/dtstate
nsr 2 worktree-guard.sh "$nostate" Write "$S/custom/dtstate/k/approvals/T1.plan" DELIVER_TICKET_HOME=$S/custom/dtstate
nsr 2 guard.sh "$X" Bash "cd $S/custom/dtstate/k && echo x > closed/T1" DELIVER_TICKET_HOME=$S/custom/dtstate
nsr 2 worktree-guard.sh "$nostate" Write "$S/link-root/k/closed/T1" DELIVER_TICKET_HOME=$S/link-root
nsr 2 worktree-guard.sh "$nostate" Write "$S/real-root/k/closed/T1" DELIVER_TICKET_HOME=$S/link-root
nsr 0 worktree-guard.sh "$nostate" Write "$S/custom/dtstate/k/closed/T1"                       # the default root is $DT here, so another root's path is not protected
echo "## default root under HOME: ~ / \$HOME / \${HOME} forms and relative spellings from a parent cwd"
H=$S/fakehome; D='.local/share/deliver-ticket'
nsr 2 guard.sh "$nostate" Bash "echo x > ~/$D/k/closed/T1" -u DELIVER_TICKET_HOME HOME=$H
nsr 2 guard.sh "$nostate" Bash "echo x > \$HOME/$D/k/closed/T1" -u DELIVER_TICKET_HOME HOME=$H
nsr 2 guard.sh "$nostate" Bash "echo x > \${HOME}/$D/k/closed/T1" -u DELIVER_TICKET_HOME HOME=$H
nsr 2 guard.sh "$nostate" Bash "cd ~/$D && echo x > k/closed/T1" -u DELIVER_TICKET_HOME HOME=$H
nsr 2 guard.sh "$H" Bash "echo x > $D/k/closed/T1" -u DELIVER_TICKET_HOME HOME=$H                  # relative path, cwd = the parent of the root
nsr 2 guard.sh "$H" Bash "cd .local/share && cd deliver-ticket && echo x > k/closed/T1" -u DELIVER_TICKET_HOME HOME=$H
nsr 2 worktree-guard.sh "$H" Write "$D/k/closed/T1" -u DELIVER_TICKET_HOME HOME=$H                 # relative Write path
nsr 2 guard.sh "$DT/$key" Bash "echo x > closed/T1"                                                 # cwd inside the root: the payload's cwd names it
nsr 2 guard.sh "$H/$D/k" Bash "echo x > closed/T1" -u DELIVER_TICKET_HOME HOME=$H
echo "## the skill dir's own path is not a hit (its name is the default root's name); a ../.. spelling out of it still is"
nsr 0 guard.sh "$SK" Bash "echo x > \$UNSET_A2/y" -u DELIVER_TICKET_HOME HOME=$H
nsr 0 guard.sh "$nostate" Bash "bash $SK/scripts/session-map.sh show" -u DELIVER_TICKET_HOME HOME=$H
nsr 2 guard.sh "$SK" Bash "cat $SK/../../../.local/share/deliver-ticket/x; echo x > \$UNSET_A2/y" -u DELIVER_TICKET_HOME HOME=$H   # hit -> the unresolvable target blocks
nsr 2 guard.sh "$SK" Bash "echo x > $SK/../../../.local/share/deliver-ticket/k/closed/T1" -u DELIVER_TICKET_HOME HOME=$(dirname "$(dirname "$(dirname "$SK")")")    # the real default root of this machine's HOME, reached through the skill dir
echo "## on a hit an unresolvable target blocks; on a miss it does not"
nsr 2 guard.sh "$nostate" Bash "cat $DT/lessons.md; echo x > \$UNSET_A2/y"
nsr 2 guard.sh "$nostate" Bash "echo x > \$(echo $DT)/k/closed/T1"
nsr 2 guard.sh "$nostate" Bash "cd \$UNSET_A2 && echo $DT >/dev/null; echo x > rel.txt"
nsr 2 guard.sh "$nostate" Bash "echo $DT; echo 'unterminated"                                       # unparsable on a hit
MISS=DELIVER_TICKET_HOME=$S/zqroot                             # a root whose name appears nowhere in the payloads below (the harness root is called "state", which "nostate" contains)
nsr 0 guard.sh "$nostate" Bash "echo x > \$UNSET_A2/y" $MISS
nsr 0 guard.sh "$nostate" Bash "echo 'unterminated" $MISS
echo "## fail-closed when python3 is missing or crashes (hit); no python at all on a miss"
NB=$S/bin-nopy; NS=$S/bin-stub; mkdir -p "$NB" "$NS"
for t in git sed head cut shasum dirname basename cat touch; do ln -sf "$(command -v $t)" "$NB/$t"; ln -sf "$(command -v $t)" "$NS/$t"; done
printf '#!/bin/sh\ntouch "%s/stub-called"\nexit 1\n' "$S" > "$NS/python3"; chmod +x "$NS/python3"
nsr 0 guard.sh "$nostate" Bash "echo hi" PATH="$NS" $MISS
nsr 0 worktree-guard.sh "$nostate" Write "$nostate/a.txt" PATH="$NS" $MISS
nsr 0 guard.sh "$nostate" Bash "echo hi" PATH="$NB" $MISS
[ ! -e "$S/stub-called" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL nostate: python3 was started on a miss"; }
nsr 2 guard.sh "$nostate" Bash "echo x > $PC" PATH="$NB"
nsr 2 worktree-guard.sh "$nostate" Write "$PC" PATH="$NB"
nsr 2 guard.sh "$nostate" Bash "echo x > $PC" PATH="$NS"
[ -e "$S/stub-called" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL nostate: the stub python3 should have been called on a hit"; }
echo "## nostate reuses protected_state (so what protected_state covers later, e.g. guard.json, is covered here too)"
python3 - "$SK/hooks" <<'PY' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL nostate does not go through protected_state"; }
import sys; sys.path.insert(0, sys.argv[1]); import dtcore
dtcore.protected_state = lambda rp: rp.endswith("/MARK")
try:
    dtcore.nostate_path("/x/MARK", None, {}); sys.exit(1)
except dtcore.Block:
    pass
dtcore.nostate_path("/x/OK", None, {})
PY
echo "# C9b: the configuration the hooks trust is protected in every cwd: ~/.claude/settings*, the skill dir (unless the session STARTED in the skill repo),"
echo "#      a delivery repo's .claude/settings*.json and worktrees/*/.claude/settings*.json, the git / ssh / gh / glab group"
mkdir -p "$DT/starts" "$S/elsewhere2" "$S/lnstarts/real" "$nostate/.claude"
printf '%s\n' "$SK" > "$DT/starts/ns-skill"; printf '%s\n' "$SK/hooks" > "$DT/starts/ns-sub"; printf '%s\n' "$S/elsewhere2" > "$DT/starts/ns-else"
printf '%s\n' "$SK" > "$S/skill-rec"; ln -s "$S/skill-rec" "$DT/starts/ns-link"
printf '%s\n' "$SK" > "$S/lnstarts/real/ns-skill"; ln -s "$S/lnstarts/real" "$S/lnstarts/starts"
for NSSID in ns-skill ns-sub; do                               # started in the skill repo (or inside it): the skill dir is writable from a no-state cwd, settings are not
  for cwd in "$nostate" "$X"; do
    nsr 0 worktree-guard.sh "$cwd" Write "$SK/hooks/c9b-probe.sh"; nsr 0 worktree-guard.sh "$cwd" Edit "$SK/stages/c9b.md"
    nsr 0 guard.sh "$cwd" Bash "echo x > $SK/hooks/c9b-probe.sh"; nsr 0 guard.sh "$cwd" Bash "sed -i '' s/a/b/ $SK/SKILL.md"
    nsr 0 guard.sh "$SK" Bash "echo x > hooks/c9b-probe.sh"
  done
done
for NSSID in ns-else ns-link nsu ns-missing; do                # started elsewhere, a symlinked record, no record (nsu, ns-missing): blocked on every route
  for cwd in "$nostate" "$X" "$SK"; do
    for tool in Write Edit NotebookEdit MultiEdit; do nsr 2 worktree-guard.sh "$cwd" $tool "$SK/hooks/c9b-probe.sh"; done
    for c in "echo x > $SK/hooks/c9b-probe.sh" "echo x >> $SK/scripts/x.sh" "tee $SK/SKILL.md" "cp /dev/null $SK/hooks/lib.sh" "sed -i '' s/a/b/ $SK/SKILL.md" "touch $SK/x" \
      "rm -rf $SK" "rm $SK/hooks/*" "mv $SK $S/moved" "rm -rf ~/.claude/skills" "cp -R $S/x $SK/hooks" "ln -s $S/x $SK/hooks/y"; do nsr 2 guard.sh "$cwd" Bash "$c"; done
  done
  nsr 2 guard.sh "$SK" Bash "echo x > hooks/c9b-probe.sh"     # the payload cwd follows an earlier `cd <skill dir>` (probe 2026-11-16): it does not count
  nsr 0 guard.sh "$nostate" Bash "cat $SK/SKILL.md"; nsr 0 guard.sh "$SK" Bash "git status"; nsr 0 guard.sh "$nostate" Bash "echo x > $S/c9b-out.txt"
done
NSSID=ns-skill; nsr 2 worktree-guard.sh "$nostate" Write "$SK/hooks/c9b-probe.sh" DELIVER_TICKET_HOME=$S/lnstarts       # starts/ itself a symlink: ignored
nsr 2 guard.sh "$nostate" Bash "echo x > $SK/x" DELIVER_TICKET_HOME=$S/lnstarts
NSSID=ns-skill; tsid 2 guard.sh ns-skill "$W" "echo x > $SK/hooks/x"     # in a repo with delivery state the existing ~/.claude rule stays as it is
for NSSID in ns-skill nsu; do
  for cwd in "$nostate" "$X"; do
    for p in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" "$HOME/.claude/settings.json.bak-deliver-ticket-1" "$R/.claude/settings.json" \
      "$R/.claude/settings.local.json" "$W/.claude/settings.local.json" "$W/.claude/settings.json" "$HOME/.gitconfig" "$HOME/.ssh/config" "$HOME/.ssh/known_hosts" "$HOME/.netrc"; do
      for tool in Write Edit; do nsr 2 worktree-guard.sh "$cwd" $tool "$p"; done
      nsr 2 guard.sh "$cwd" Bash "echo x > $p"; nsr 2 guard.sh "$cwd" Bash "cp /dev/null $p"
    done
    for c in 'echo x > ~/.claude/settings.json' 'rm ~/.claude/settings*' 'mv ~/.claude ~/c' "cp -R $S/x ~/.claude" "cp -R $S/x $R/.claude" "cp -R $S/x $W/.claude" \
      "rm -rf $R/.claude" 'git config --global core.sshCommand x' 'git config --global --add credential.helper x' 'echo x >> ~/.config/gh/hosts.yml' \
      "cd $R/.claude && echo x > settings.local.json"; do nsr 2 guard.sh "$cwd" Bash "$c"; done
    for c in 'git config --global --get user.name' 'cat ~/.claude/settings.json' "cp -R $S/x $nostate/.claude" "echo x > $nostate/.claude/settings.json" \
      "echo x > $HOME/.claude/projects/x/memory/m.md" "echo x > $S/settings.json"; do nsr 0 guard.sh "$cwd" Bash "$c"; done
    nsr 0 worktree-guard.sh "$cwd" Write "$nostate/.claude/settings.local.json"        # a project without delivery state: the update-config workflow
    nsr 0 worktree-guard.sh "$cwd" Write "$HOME/.claude/projects/x/memory/m.md"         # auto-memory stays writable
    nsr 0 worktree-guard.sh "$cwd" Write "$HOME/.claude/plans/p.md"                    # the rest of ~/.claude: today's behaviour from a no-state cwd
  done
done
NSSID=nsu
echo "## C9b: in the repo with delivery state, its own settings files are protected for bound and unbound sessions (bound: also its own worktree's)"
for sid in s1 u1; do
  for p in "$R/.claude/settings.json" "$R/.claude/settings.local.json" "$W/.claude/settings.local.json" "$W3/.claude/settings.json"; do
    wsid 2 $sid "$W" Write "{\"file_path\":\"$p\"}"; tsid 2 guard.sh $sid "$W" "echo x > $p"
  done
  wsid 0 $sid "$W" Write "{\"file_path\":\"$HOME/.claude/projects/x/memory/m.md\"}"
done
tsid 2 guard.sh s1 "$W" 'mkdir -p .claude && echo x > .claude/settings.local.json'
tsid 0 guard.sh u1 "$R" "echo x > $nostate/.claude/settings.json"
echo "## C9b prefilter: transcript_path (always under ~/.claude/projects) alone does not start python; a .claude / config / .ssh / .netrc name does"
NS2=$S/bin-stub2; mkdir -p "$NS2"; for t in git sed head cut shasum dirname basename cat touch; do ln -sf "$(command -v $t)" "$NS2/$t"; done
printf '#!/bin/sh\ntouch "%s/stub2-called"\nexit 1\n' "$S" > "$NS2/python3"; chmod +x "$NS2/python3"
tp() { jq -nc --arg cwd "$nostate" --arg cmd "$1" --arg tp "$HOME/.claude/projects/-x-deliver-ticket/s.jsonl" '{session_id:"nsu",transcript_path:$tp,cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$cmd}}' \
  | env PATH="$NS2" DELIVER_TICKET_HOME=$S/zqroot "$SK/hooks/guard.sh" >/dev/null 2>&1; echo $?; }
req "$(tp 'echo hi')" 0 "transcript_path only: allowed"
[ ! -e "$S/stub2-called" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL prefilter: transcript_path alone started python"; }
for c in 'echo x > ~/.claude/settings.json' 'git config --global a.b c' 'cat ~/.ssh/id' 'cat ~/.netrc'; do
  req "$(tp "$c")" 2 "prefilter hit (stub python exits 1 = fail-closed block): $c"
done
echo "# C1: case-insensitive filesystems: CLOSED/t1 is closed/T1 there, so the guard must compare case-insensitively (detected, not assumed)"
mkdir -p "$S/CiProbe"; if [ -d "$S/ciprobe" ]; then SCI=2; else SCI=0; fi         # what the scratch filesystem (state root) does with a case-swapped name
if [ -d "$HOME/.CLAUDE" ]; then HCI=2; else HCI=0; fi                             # the same for $HOME/.claude
echo "scratch fs case-insensitive: $([ $SCI = 2 ] && echo yes || echo no); \$HOME fs: $([ $HCI = 2 ] && echo yes || echo no)"
mkdir -p "$DT/$key/closed"                                                       # (no marker file: closed/T1 would close the open ticket T1 that the case-variant cwd tests below need)
for v in "$DT/$key/CLOSED/T1" "$DT/$key/Closed/t1" "$DT/$key/closed/t1" "$DT/$key/DELIVERY.LOG" "$DT/$key/Delivery.Log" "$DT/SESSIONS/zz" "$DT/Sessions/s1"; do
  for sid in s1 u1; do wsid $SCI $sid "$R" Write "{\"file_path\":\"$v\"}"; wsid $SCI $sid "$R" Edit "{\"file_path\":\"$v\"}"; tsid $SCI guard.sh $sid "$R" "echo x > $v"; tsid $SCI guard.sh $sid "$R" "touch $v"; done
  NSSID=nsu; nsr $SCI worktree-guard.sh "$nostate" Write "$v"; nsr $SCI guard.sh "$nostate" Bash "echo x > $v"
  nsr $SCI guard.sh "$X" Bash "echo x >> $v"; NSSID=tk; nsr $SCI worktree-guard.sh "$nostate" Edit "$v"; NSSID=nsu
done
echo "## ~/.claude in another case (bound and unbound session); the no-state cwd does not apply this rule at all"
for sid in s1 u1; do wsid $HCI $sid "$R" Write "{\"file_path\":\"$HOME/.CLAUDE/settings.json\"}"; wsid $HCI $sid "$R" Write "{\"file_path\":\"$HOME/.Claude/skills/x/SKILL.md\"}"; tsid $HCI guard.sh $sid "$R" "echo x > $HOME/.CLAUDE/settings.json"; done
echo "## the exact spelling and an unrelated case-variant stay as before"
wsid 2 u1 "$R" Write "{\"file_path\":\"$DT/$key/closed/T1\"}"
wsid 0 u1 "$R" Write "{\"file_path\":\"$DT/LESSONS.md\"}"                                     # not a protected name in any case
wsid 0 u1 "$R" Write "{\"file_path\":\"$R/Docs-new.md\"}"
echo "## a case-variant cwd / mapped worktree inside a ticket worktree binds the real ticket token (T1), never \"..\""
if [ $SCI = 2 ]; then
  WV=${W/\/repo\//\/REPO\/}                                                    # same directory, other spelling of one component
  [ -d "$WV" ] || { fail=$((fail+1)); echo "FAIL C1 setup: $WV is not a directory"; }
  msg=$(jq -nc --arg cwd "$WV" --arg f "$R/docs/x.md" '{session_id:"cv1",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$f}}' | "$SK/hooks/worktree-guard.sh" 2>&1); rc=$?
  { [ $rc = 2 ] && echo "$msg" | grep -q 'bound to ticket T1'; } && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL case-variant cwd must bind ticket T1: rc=$rc $msg"; }
  wsid 0 cv1 "$WV" Write "{\"file_path\":\"$W/src/a.ts\"}"                    # its own worktree stays writable
  printf 'project=%s\nworktree=%s\n' "$key" "$WV" > "$DT/sessions/cv2"          # EnterWorktree recorded the variant spelling
  wsid 2 cv2 "$R" Write "{\"file_path\":\"$R/docs/x.md\"}"
  wsid 0 cv2 "$R" Write "{\"file_path\":\"$W/src/a.ts\"}"
fi
python3 - "$SK/hooks" <<'PY' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL C1 unit: first_component"; }
import sys; sys.path.insert(0, sys.argv[1]); import dtcore
fc = dtcore.first_component
assert fc("/a/b/T1/src", "/a/b") == "T1" and fc("/A/B/T1", "/a/b") == "T1" and fc("/a/b", "/a/b") == "." and fc("/a/b/x", "/a/b") == "x"
PY
echo "## exact comparison where detection says case-sensitive (fs_ci patched)"
python3 - "$SK/hooks" <<'PY' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL C1 unit: under() case handling"; }
import sys; sys.path.insert(0, sys.argv[1]); import dtcore
dtcore.fs_ci = lambda root: False
assert not dtcore.under("/a/B/c", "/a/b") and dtcore.under("/a/b/c", "/a/b")
dtcore._CI.clear(); dtcore.fs_ci = lambda root: True
assert dtcore.under("/a/B/c", "/a/b") and dtcore.under("/A/b", "/a/B") and not dtcore.under("/a/bc", "/a/b")
PY
echo "# B1: guard.json is protected state (written only by scripts/guard-write.sh); deleting / moving / linking the state is blocked too"
G=$DT/$key/guard.json; GU=$DT/$key/GUARD.JSON; GM=$DT/$key/Guard.Json; GO=$DT/other-12345678/guard.json
# gx <expect-rc> <tool> <path-or-command>: the same call in six contexts - a ticket session and a session without a ticket in the initialised repo,
# and, in a git repo without state and in a non-git dir, a session without a ticket and one with an open ticket in its map
gx() { local exp=$1 tool=$2 arg=$3 kf=file_path cwd
  if [ "$tool" = Bash ]; then
    tsid $exp guard.sh s1 "$R" "$arg"; tsid $exp guard.sh u1 "$R" "$arg"
    for NSSID in nsu tk; do for cwd in "$nostate" "$X"; do nsr $exp guard.sh "$cwd" Bash "$arg"; done; done
  else
    [ "$tool" = NotebookEdit ] && kf=notebook_path
    wsid $exp s1 "$R" $tool "{\"$kf\":\"$arg\"}"; wsid $exp u1 "$R" $tool "{\"$kf\":\"$arg\"}"
    for NSSID in nsu tk; do for cwd in "$nostate" "$X"; do nsr $exp worktree-guard.sh "$cwd" $tool "$arg"; done; done
  fi; NSSID=nsu; }
echo "## edit tools onto guard.json (also another project's, and upper / mixed case where the filesystem folds it)"
for tool in Write Edit NotebookEdit MultiEdit; do gx 2 $tool "$G"; gx 2 $tool "$GO"; gx $SCI $tool "$GU"; gx $SCI $tool "$GM"; done
echo "## shell routes onto guard.json"
for c in "echo x > $G" "echo x >> $G" ": > $G" "tee $G" "touch $G" "cp /dev/null $G" "mv /tmp/zz-b1 $G" "mv $G /tmp/zz-b1" "rm $G" "rm -f $G" "unlink $G" \
  "truncate -s0 $G" "shred -u $G" "sed -i '' s/a/b/ $G" "dd if=/dev/null of=$G" "ln -sf /tmp/zz-b1 $G" "install /dev/null $G" "curl -o $G http://x.invalid" \
  "chmod 000 $G" "link /tmp/zz-b1 $G" "echo x > $GO" "rm $GO"; do gx 2 Bash "$c"; done
for c in "echo x > $GU" "rm -f $GU" "mv /tmp/zz-b1 $GM" "truncate -s0 $GM"; do gx $SCI Bash "$c"; done
echo "## hard links to protected state (a write through the link edits the same file); symlinks are not hard links"
for c in "ln $G /tmp/zz-hl" "ln -f $G /tmp/zz-hl" "link $G /tmp/zz-hl" "cp -l $G /tmp/zz-hl" "cp --link $G /tmp/zz-hl" "cp -al $G /tmp/zz-hl" "cp -lr $DT/$key/closed/T1 /tmp/zz-hl" \
  "ln $DT/sessions/s1 /tmp/zz-hl" "ln $DT/$key/delivery.log /tmp/zz-hl" "ln -t /tmp $G"; do gx 2 Bash "$c"; done
echo "## removing or moving the state root, a parent of it, a project state dir or sessions/ - with a specific reason"
for c in "rm -r $DT/$key" "rm -rf $DT/$key/" "mv $DT/$key /tmp/zz-key" "rmdir $DT/$key" "rm -rf $DT" "rm -rf $DT/sessions" "mv $DT/sessions /tmp/zz-s" "unlink $DT/sessions" "shred $DT/$key" \
  "rm -rf $S" "mv $S /tmp/zz-S" "cd $DT && rm -rf $key" "cd $DT/$key && rm -rf ." "cd $DT/$key && rm -rf ../$key" "cd $DT && rm -rf ." "cd $S && rm -rf state"; do gx 2 Bash "$c"; done
echo "## globs: block only when the glob can match the next component toward protected state"
for c in "rm -rf $DT/*" "rm -rf $DT/$key/*" "rm -f $DT/$key/guard.*" "rm -f $DT/$key/guard.js*" "rm -rf $DT/sessions/*" "rm $DT/*/closed/*" "rm -rf $DT/$key/clo*" "touch $DT/$key/guard.js*" "rm -rf $DT/se*" "rm -rf $DT/re*" "rm -rf $S/*" "rm -rf $S/sta*"; do gx 2 Bash "$c"; done
# a path next to the state root is outside a bound session's write allowlist when the scratch dir is not under /tmp (the hook then says so, rc 2, for s1 only)
gxS() { case "$S" in /tmp/*|/private/tmp/*) gx 0 Bash "$1" ;; *) tsid 2 guard.sh s1 "$R" "$1"; tsid 0 guard.sh u1 "$R" "$1"; for NSSID in nsu tk; do for cwd in "$nostate" "$X"; do nsr 0 guard.sh "$cwd" Bash "$1"; done; done; NSSID=nsu ;; esac; }
for c in "rm -rf $DT/$key/evidence/*" "rm -rf $DT/zz*"; do gx 0 Bash "$c"; done
for c in "rm -rf $S/foo*" "rm -rf $S/foo/*"; do gxS "$c"; done
echo "## ~/.local/share/deliver-ticket under a fake HOME: every parent, and globs toward it"
H=$S/fakehome
for c in 'rm -rf ~/.local/share' 'rm -rf ~/.local' 'mv ~/.local /tmp/zz-x' 'rm -rf ~' 'rm -rf $HOME' 'rm -rf ~/.local/share/*' 'rm -rf ~/.local/share/deliver-*' 'rm -rf ~/.local/*' 'rm -rf ~/.local/share/deliver-ticket' 'rm -rf ~/*' \
  'rm -rf ~/.local/share/deliver-ticket/k' 'rm -rf ~/.local/share/deliver-ticket/*'; do nsr 2 guard.sh "$nostate" Bash "$c" -u DELIVER_TICKET_HOME HOME=$H; nsr 2 guard.sh "$H" Bash "$c" -u DELIVER_TICKET_HOME HOME=$H; done
nsr 2 guard.sh "$H" Bash 'cd .local/share && rm -rf deliver-ticket' -u DELIVER_TICKET_HOME HOME=$H
nsr 2 guard.sh "$H/.local" Bash 'rm -rf share' -u DELIVER_TICKET_HOME HOME=$H
for c in 'rm -rf ~/.local/share/foo*' 'rm -rf ~/.local/share/foo' 'rm -rf ~/.local/zz*' 'rm -rf ~/.cache' 'rm -rf ~/.local/share/deliver-ticket/k/evidence' 'cat ~/.local/share/deliver-ticket/k/guard.json'; do nsr 0 guard.sh "$nostate" Bash "$c" -u DELIVER_TICKET_HOME HOME=$H; done
echo "## a root whose name the payload does not spell: the delete / move verb alone triggers the check (resolvable targets only)"
mkdir -p "$S/zqroot/k"
for c in "rm -rf $S" "mv $S /tmp/zz-S" "rm -rf $S/*" "rm -rf $S/zq*" "unlink $S" "rmdir $S" "rm -rf $S/zqroot/k" "cd $S && rm -rf ."; do nsr 2 guard.sh "$nostate" Bash "$c" $MISS; nsr 2 guard.sh "$X" Bash "$c" $MISS; done
for c in "/bin/rm -rf $S" "/usr/bin/rm -rf $S" "\\rm -rf $S" "command rm -rf $S" "/bin/mv $S /tmp/zz-S" "/usr/bin/env rm -rf $S" "$(printf 'rm\t-rf %s' "$S")" "$(printf 'cd /tmp\n/bin/rm -rf %s' "$S")" "echo x;/bin/rm -rf $S"; do nsr 2 guard.sh "$nostate" Bash "$c" $MISS; done
for c in "rm -rf /tmp/zz-b1-dir" "rm -rf \$UNSET_B1/x" "cd \$UNSET_B1 && rm -rf x" "rm -rf $S/other" "mv /tmp/zz-b1 /tmp/zz-b2" "echo 'unterminated rm -rf x"; do nsr 0 guard.sh "$nostate" Bash "$c" $MISS; nsr 0 guard.sh "$X" Bash "$c" $MISS; done
msg=$(payload "$R" Bash "rm -rf $DT/$key" u1 | "$SK/hooks/guard.sh" 2>&1); echo "$msg" | grep -q 'disable every guard' && echo "$msg" | grep -q 'project state dir' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL specific reason for deleting the state: $msg"; }
msg=$(payload "$R" Bash "ln $G /tmp/zz-hl" u1 | "$SK/hooks/guard.sh" 2>&1); echo "$msg" | grep -q 'hard link' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL specific reason for a hard link: $msg"; }
echo "## still allowed (rc 0) in all six contexts: reads, the candidate, other state files, symlinks, deleting something that is not an ancestor"
for c in "cat $G" "jq . $G" "grep key $G" "touch $DT/$key/guard.candidate.json" "echo x > $DT/$key/guard.candidate.json" "rm $DT/$key/evidence/x" "rm -rf /tmp/zz-b1-dir" "ln -s $G /tmp/zz-sl" \
  "cd $DT/$key && cat guard.json" "ls $DT" "mv /tmp/zz-b1 /tmp/zz-b2"; do gx 0 Bash "$c"; done
for tool in Write Edit; do gx 0 $tool "$DT/$key/guard.candidate.json"; done
gxS "rm -rf $S/other"
echo "## skill scripts stay allowed, also with a corrupt guard.json (the repair path)"
for c in "$SK/scripts/guard-write.sh diff $DT/$key/guard.candidate.json --repo $R" "bash $SK/scripts/guard-write.sh verify --repo $R"; do gx 0 Bash "$c"; done
echo "# C3: command names are case-insensitive on a case-insensitive filesystem (GIT --version runs git): every program-name rule folds case"
for c in 'GIT push --force mirror main' 'Git push mirror feat-T1' 'GIT -C . push mirror feat-T1' '/usr/bin/GIT push mirror feat-T1' '/USR/BIN/Git push mirror feat-T1' 'ENV git push mirror feat-T1' 'Env HUSKY=0 git commit -m x' \
  'GH pr edit 1' 'Glab mr update 1' 'GLAB api /x' 'GH pr create -t x' 'Gh -R o/r pr edit 1' 'BASH -c "git push mirror feat-T1"' 'EVAL git push mirror feat-T1' \
  'PYTHON3 -c "print(open(\".env\").read())"' 'Node -e "require(\"fs\").readFileSync(\".env\")"' 'PERL -e "open(F,\".env\")"'; do
  for sid in s1 u1; do tsid 2 guard.sh $sid "$W" "$c"; done
done
for sid in s1 u1; do for c in 'GREP -r K sr2' 'Rg --hidden K sr2' 'Egrep -r K sr2'; do tsid 2 guard.sh $sid "$R" "$c"; done; done
tsid 2 guard.sh s1 "$W3" 'GIT merge feat-T1'
for c in 'GIT status' 'Git log --oneline' 'LS -la' 'GH pr view 1' 'Echo hi' 'CAT README'; do for sid in s1 u1; do tsid 0 guard.sh $sid "$W" "$c"; done; done
for c in "TOUCH $R/docs/q.md" "Tee $R/docs/q.md" "CP /dev/null $R/docs/q.md" "SED -i '' s/a/b/ $R/docs/q.md" "Mv /tmp/zz-c3 $R/docs/q.md" "DD of=$R/docs/q.md"; do tsid 2 guard.sh s1 "$R" "$c"; done
for c in "RM -rf $DT/$key" "Mv $DT/$key /tmp/zz-c3" "RM -rf $DT" "UNLINK $DT/$key/guard.json" "TRUNCATE -s0 $DT/$key/guard.json" "Shred $DT/$key/guard.json" "LN $DT/$key/guard.json /tmp/zz-hl" "CP -l $DT/$key/guard.json /tmp/zz-hl" "TEE $DT/$key/guard.json" "TOUCH $DT/$key/closed/T9"; do gx 2 Bash "$c"; done
for c in "RM -rf $S" "/BIN/RM -rf $S" "\\RM -rf $S" "Mv $S /tmp/zz-c3" "ENV rm -rf $S" "echo x;Unlink $S"; do for cwd in "$nostate" "$X"; do nsr 2 guard.sh "$cwd" Bash "$c" $MISS; done; done
python3 - "$SK/hooks" <<'PY' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL C3 unit: pname / analyze"; }
import sys; sys.path.insert(0, sys.argv[1]); import dtcore
assert dtcore.pname("/Usr/Bin/GIT") == "git" and dtcore.pname("Rm") == "rm"
c = dtcore.analyze("ENV GIT push mirror x", "/tmp")[0]
assert c.argv[0] == "GIT" and c.prefix == ["ENV"], (c.argv, c.prefix)
assert [x.argv[:2] for x in dtcore.analyze('BASH -c "RM -rf x"', "/tmp")][-1] == ["RM", "-rf"]
assert dtcore.analyze("EXPORT FOO=1", "/tmp")[0].argv[0] == "EXPORT"
PY
echo "# G1: a gate action (guard-apply.sh, ticket-state.sh) only as <skill>/scripts/<name>.sh with nothing in front: the ask rule on that path is the user's yes"
SKS=$SK/scripts
for c in "python3 $SKS/guard_apply.py c.json --repo $R" "bash $SKS/guard-apply.sh c.json --repo $R" "sh $SKS/ticket-state.sh done T1 --reason x --repo $R" "bash $SKS/ticket-state.sh done T1 --reason x --repo $R" \
  "python3 $SKS/ticket_ctl.py ticket-state done T1 --reason x --repo $R" "python3 -I $SKS/ticket_ctl.py ticket-state cancelled T1 --reason x --repo $R" "env $SKS/guard-apply.sh c.json --repo $R" \
  "FOO=1 $SKS/ticket-state.sh done T1 --reason x --repo $R" "cd $SKS && ./guard-apply.sh c.json --repo $R" "bash -c \"$SKS/guard-apply.sh c.json --repo $R\"" \
  "echo \$($SKS/ticket-state.sh done T1 --reason x --repo $R)" "$SKS/../scripts/guard-apply.sh c.json --repo $R" "xargs $SKS/guard-apply.sh" "BASH $SKS/guard-apply.sh c.json --repo $R" \
  "command $SKS/ticket-state.sh done T1 --reason x --repo $R" "nohup $SKS/guard-apply.sh c.json --repo $R" "python3 $SKS/guard_apply.py"; do gx 2 Bash "$c"; done
echo "# C7: approve-plan.sh is a gate action too (its prompt is the user's yes to the plan): only the absolute spelling, and not through its module"
for c in "bash $SKS/approve-plan.sh T1 --repo $R" "python3 $SKS/approve_plan.py T1 --repo $R" "python3 -I $SKS/approve_plan.py T1 --repo $R" "env $SKS/approve-plan.sh T1 --repo $R" "FOO=1 $SKS/approve-plan.sh T1 --repo $R" \
  "cd $SKS && ./approve-plan.sh T1 --repo $R" "bash -c \"$SKS/approve-plan.sh T1 --repo $R\"" "echo \$($SKS/approve-plan.sh T1 --repo $R)" "$SKS/../scripts/approve-plan.sh T1 --repo $R"; do gx 2 Bash "$c"; done
for c in "$SKS/approve-plan.sh T1 --repo $R --session s1" "$SKS/git-push.sh mirror feat-T1" "$SKS/git-rename.sh a b"; do gx 0 Bash "$c"; done
# the read-only, sandboxed scripts (install_hooks.SANDBOXED) of stage 2 and stage 8 pass the hooks in every session
for c in "$SKS/plan-hash.sh T1 --repo $R" "$SKS/lock-trace.sh T1 --repo $R --session s1"; do gx 0 Bash "$c"; done
for c in "bash $SKS/git-push.sh mirror feat-T1" "python3 $SKS/git_push.py mirror feat-T1" "env $SKS/git-push.sh mirror feat-T1" "FOO=1 $SKS/git-push.sh mirror feat-T1" "cd $SKS && ./git-push.sh mirror feat-T1"; do gx 2 Bash "$c"; done
for c in "$SKS/guard-apply.sh c.json --repo $R" "$SKS/guard-apply.sh --repo $R c.json" "$SKS/ticket-state.sh done T1 --reason x --repo $R" "$SKS/ticket-state.sh reopen T1 --reason x --repo $R" \
  "bash $SKS/session-map.sh show T1 --session s --repo $R" "python3 $SKS/ticket_ctl.py session-map show T1 --session s --repo $R" "bash $SKS/guard-write.sh verify --repo $R" \
  "bash $SKS/guard-write.sh diff c.json --repo $R" "python3 $SKS/validate-guard.py x.json" "bash $SKS/pending-ticket.sh save T1 --repo $R" "bash $SKS/project-map-stale.sh check p.md --guard g.json"; do gx 0 Bash "$c"; done
# case variants resolve to the same file on a case-insensitive filesystem, but the ask rule is a literal prefix: only the exact spelling is allowed
if [ -d "${SK/deliver-ticket/DELIVER-TICKET}" ]; then
  UP=${SK/deliver-ticket/DELIVER-TICKET}; DOT=${SKS/.claude/.CLAUDE}
  for c in "$SKS/GUARD-APPLY.sh c.json --repo $R" "$SKS/Guard-Apply.sh c.json --repo $R" "$SKS/Ticket-State.sh done T1 --reason x --repo $R" "$SKS/TICKET-STATE.SH done T1 --reason x --repo $R" \
    "python3 $SKS/GUARD_APPLY.PY c.json --repo $R" "python3 $SKS/Ticket_Ctl.py ticket-state done T1 --reason x --repo $R"; do gx 2 Bash "$c"; done
  # a skill dir outside ~/.claude/skills/deliver-ticket (the dev clone) has no such part to change: the "variant" would be the exact spelling
  if [ "$UP" != "$SK" ]; then gx 2 Bash "$UP/scripts/guard-apply.sh c.json --repo $R"; else echo "skipped: 1 case-variant case = 6 checks (no deliver-ticket in $SK)"; fi
  if [ "$DOT" != "$SKS" ]; then for c in "$DOT/guard-apply.sh c.json --repo $R" "$DOT/ticket-state.sh done T1 --reason x --repo $R"; do gx 2 Bash "$c"; done
  else echo "skipped: 2 case-variant cases = 12 checks (no .claude in $SKS)"; fi
  gx 0 Bash "$SKS/guard-apply.sh c.json --repo $R"
fi
python3 - "$SK/hooks" "$SK/scripts" <<'PY' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL G1 unit: hook GATE_SCRIPTS vs install_hooks.GATES"; }
import os, sys
sys.path.insert(0, sys.argv[1]); sys.path.insert(0, sys.argv[2]); os.environ["DT_SETTINGS"] = "/nonexistent"
import dtcore, install_hooks as ih
assert dtcore.GATE_SCRIPTS == set(ih.GATES), (dtcore.GATE_SCRIPTS, ih.GATES)
assert set(dtcore.GATE_MODULES) == {"guard_apply.py", "ticket_ctl.py", "git_push.py", "approve_plan.py"}
PY
echo "# C6 audit: no excluded script (bookkeeping or gate) and no module behind one names approvals/ - only the C7 writer (ticket_ctl.py approve-plan, approve-plan.sh) will"
python3 - "$SK/scripts" <<'PY' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL C6 audit: a script names approvals/"; }
import glob, os, sys
allowed = {"install_hooks.py", "probe_sandbox.py", "approve-plan.sh", "approve_plan.py", "plan_lock.py", "lock_trace.py"}      # the gate writer, plus plan_lock.py (read-only helpers shared with the C8 lock check) and lock_trace.py (C10, read-only, sandboxed: denyWrite covers approvals/); anything else naming approvals/ is a new, unaudited writer
bad = [os.path.basename(f) for f in glob.glob(sys.argv[1] + "/*") if os.path.isfile(f) and "approvals" in open(f, errors="replace").read() and os.path.basename(f) not in allowed]
assert not bad, bad
PY
echo "# I1: the installer's writing subcommands are not run by Claude, in any spelling or repo; read-only ones are"
for sub in apply uninstall project-apply project-uninstall project-sandbox-apply project-sandbox-off; do
  for c in "$SKS/install-hooks.sh $sub --repo $R --confirmed" "bash $SKS/install-hooks.sh $sub --confirmed" "sh $SKS/install-hooks.sh $sub" "python3 $SKS/install_hooks.py $sub --confirmed" \
    "python3 -I $SKS/install_hooks.py $sub --repo $R" "env DT_SETTINGS=x $SKS/install-hooks.sh $sub" "DT_SETTINGS=/tmp/zz-i1 $SKS/install-hooks.sh $sub --confirmed" "bash -c \"$SKS/install-hooks.sh $sub --confirmed\"" \
    "cd $R && $SKS/install-hooks.sh $sub" "BASH $SKS/Install-Hooks.sh $sub --confirmed" "$SKS/../scripts/install-hooks.sh --confirmed $sub"; do gx 2 Bash "$c"; done
done
for sub in status diff selftest project-status project-diff project-sandbox-status project-sandbox-diff; do
  for c in "$SKS/install-hooks.sh $sub --repo $R" "bash $SKS/install-hooks.sh $sub" "python3 $SKS/install_hooks.py $sub"; do gx 0 Bash "$c"; done
done
for c in "cat $SKS/install-hooks.sh" "grep -n apply $SKS/install_hooks.py" "$SKS/install-hooks.sh" "git diff -- $SKS/install_hooks.py" "echo apply install-hooks.sh"; do gx 0 Bash "$c"; done
python3 - "$SK/hooks" "$SK/scripts" <<'PY' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL I1 unit: hook INSTALLER_WRITING vs install_hooks"; }
import os, sys
sys.path.insert(0, sys.argv[1]); sys.path.insert(0, sys.argv[2]); os.environ["DT_SETTINGS"] = "/nonexistent"
import dtcore, install_hooks as ih
assert dtcore.INSTALLER_WRITING == set(ih.WRITING_COMMANDS), (dtcore.INSTALLER_WRITING, ih.WRITING_COMMANDS)
assert not set(ih.READ_ONLY_COMMANDS) & set(ih.WRITING_COMMANDS)
assert set(ih.READ_ONLY_COMMANDS) | set(ih.WRITING_COMMANDS) == {"status", "diff", "selftest", "apply", "uninstall", "project-status", "project-diff", "project-apply",
    "project-uninstall", "project-sandbox-status", "project-sandbox-diff", "project-sandbox-apply", "project-sandbox-off"}
PY
echo "# corrupt guard.json with state => block (except skill scripts)"
echo '{broken' > "$DELIVER_TICKET_HOME/$key/guard.json"
t 2 guard.sh "$W" 'ls'
tsid 2 guard.sh u1 "$R" 'ls'                                  # an unbound session is fail-closed too
t 0 guard.sh "$W" "python3 $SK/scripts/validate-guard.py $DELIVER_TICKET_HOME/$key/guard.json"
w 2 Write "{\"file_path\":\"$W/a\"}"
w 2 Write "{\"file_path\":\"$DELIVER_TICKET_HOME/$key/guard.json\"}"              # B1: protected even when it is broken; the repair is scripts/guard-write.sh
w 0 Write "{\"file_path\":\"$DELIVER_TICKET_HOME/$key/guard.candidate.json\"}"
t 0 guard.sh "$W" "$SK/scripts/guard-write.sh verify --repo $R"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
