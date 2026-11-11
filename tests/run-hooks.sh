#!/bin/bash
# Dry runs of the hooks against a throw-away repo. Usage: tests/run-hooks.sh <scratch-dir>
# Never touches ~/.claude/settings.json or the real state dir (DELIVER_TICKET_HOME is redirected).
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
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
printf 'stage: 3\nnext: read stages/3-build.md\nstate: active\nworktree: %s\n' "$R/.claude/worktrees/T1" > "$DELIVER_TICKET_HOME/$key/tickets/T1.md"
printf 'project=%s\nticket=T1\nworktree=%s\n' "$key" "$R/.claude/worktrees/T1" > "$DELIVER_TICKET_HOME/sessions/s1"
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
  'glab mr merge 5' 'gh pr merge 5' 'glab mr update 5 -d -' 'glab mr update 5 --description=-' 'git config alias.p "push -f"'; do t 2 guard.sh "$W" "$c"; done
echo "# push allowed through guard (rc 0)"
for c in 'git push mirror feat-T1' 'git push -u mirror feat-T1' 'git push -n mirror feat-T1' 'git status' 'git commit -m "fix: n"' 'git commit -am msg' 'ls -la' 'npm test'; do t 0 guard.sh "$W" "$c"; done
echo "# git merge: only on a ticket branch"
t 0 guard.sh "$W" 'git merge main'
t 0 guard.sh "$W" 'git merge --no-edit main'
t 0 guard.sh "$W" 'git rebase main'
t 2 guard.sh "$W3" 'git merge feat-T1'
t 2 guard.sh "$W" 'git -C ../T3 merge feat-T1'
t 2 guard.sh "$W" 'git checkout develop && git merge feat-T1'
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
echo "# verify-on-push: test=false => block; dry-run => pass"
t 2 verify-on-push.sh "$W" 'git push mirror feat-T1'
t 0 verify-on-push.sh "$W" 'git push -n mirror feat-T1'
t 0 verify-on-push.sh "$W" 'git status'
sed -i.bak 's/"test":"false"/"test":"true"/' "$DELIVER_TICKET_HOME/$key/guard.json"
t 0 verify-on-push.sh "$W" 'git push mirror feat-T1'
sed -i.bak 's/"test":"true"/"test":"sleep 30"/' "$DELIVER_TICKET_HOME/$key/guard.json"
t 2 verify-on-push.sh "$W" 'git push mirror feat-T1'
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
mkdir -p "$DELIVER_TICKET_HOME/$key/tickets"; printf 'stage: 3\nnext: read stages/3-build.md\n' > "$DELIVER_TICKET_HOME/$key/tickets/T1.md"
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
printf 'stage: 3\nnext: read stages/3-build.md\nstate: active\nworktree: %s\n' "$W" > "$DT/$key/tickets/T1.md"
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
done
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
    dtcore.nostate_path("/x/MARK", None); sys.exit(1)
except dtcore.Block:
    pass
dtcore.nostate_path("/x/OK", None)
PY
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
echo "# corrupt guard.json with state => block (except skill scripts)"
echo '{broken' > "$DELIVER_TICKET_HOME/$key/guard.json"
t 2 guard.sh "$W" 'ls'
tsid 2 guard.sh u1 "$R" 'ls'                                  # an unbound session is fail-closed too
t 0 guard.sh "$W" "python3 $SK/scripts/validate-guard.py $DELIVER_TICKET_HOME/$key/guard.json"
w 2 Write "{\"file_path\":\"$W/a\"}"
w 0 Write "{\"file_path\":\"$DELIVER_TICKET_HOME/$key/guard.json\"}"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
