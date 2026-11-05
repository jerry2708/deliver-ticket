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
echo "# corrupt guard.json with state => block (except skill scripts)"
echo '{broken' > "$DELIVER_TICKET_HOME/$key/guard.json"
t 2 guard.sh "$W" 'ls'
t 0 guard.sh "$W" "python3 $SK/scripts/validate-guard.py $DELIVER_TICKET_HOME/$key/guard.json"
w 2 Write "{\"file_path\":\"$W/a\"}"
w 0 Write "{\"file_path\":\"$DELIVER_TICKET_HOME/$key/guard.json\"}"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
