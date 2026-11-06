#!/bin/bash
# session-map.sh (pause / rebind / show) and ticket-state.sh (done / cancelled / reopen): preconditions, the delivery log,
# and the effect on the guard. Usage: tests/run-session-ctl.sh <new scratch dir>. Never deletes anything.
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
export DELIVER_TICKET_HOME=$S/state
R=$S/repo; [ -e "$R" ] && { echo "scratch dir already used: $S" >&2; exit 2; }
mkdir -p "$R" && cd "$R" && git init -q -b main && git commit -q --allow-empty -m init
echo '.claude/worktrees/' >> .git/info/exclude
key=$(printf '%s-%s' repo "$(printf '%s' "$R" | shasum -a 1 | cut -c1-8)"); ST=$DELIVER_TICKET_HOME/$key; mkdir -p "$ST/tickets" "$DELIVER_TICKET_HOME/sessions"
cat > "$ST/guard.json" <<J
{"version":1,"project_key":"$key","repo_root":"$R","base_branch":"main",
 "remotes":{"push":"mirror","allowed":["mirror"],"forbidden":["origin"]},
 "verify":{"lint":null,"test":null,"build":null,"on_push":[],"timeout_sec":20},
 "env_files":[],"install":null,"ports":{"vars":[],"base":3100,"step":10}}
J
SM=$SK/scripts/session-map.sh; TS=$SK/scripts/ticket-state.sh; MAP=$DELIVER_TICKET_HOME/sessions
pass=0; fail=0
eq() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
rc() { "$@" >/dev/null 2>&1; echo $?; }
bind() { jq -nc --arg cwd "$R" --arg sid "$1" --arg p "$2" '{session_id:$sid,cwd:$cwd,hook_event_name:"UserPromptSubmit",prompt:$p}' | "$SK/hooks/bind-session.sh"; }
write_ok() { jq -nc --arg cwd "$R" --arg f "$R/x.txt" --arg sid "$1" '{session_id:$sid,cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$f}}' | "$SK/hooks/worktree-guard.sh" >/dev/null 2>&1; echo $?; }
tf() { printf 'stage: %s\nnext: x\nstate: active   <!-- active | waiting | done -->\nworktree: none\n' "$2" > "$ST/tickets/$1.md"; }

echo "# pause at an intake stop (DoR): allowed while no worktree is recorded, logged, re-bound by the next prompt"
bind a1 '/deliver-ticket T1 hello'; eq "$(write_ok a1)" 2 "bound after the prompt"
eq "$(rc $SM show T1 --session a1 --repo $R)" 0 "show: bound"
eq "$(rc $SM pause T1 --session a1 --repo $R)" 1 "pause needs --reason"
eq "$(rc $SM pause T1 --reason 'stop (DoR)' --session a1 --repo $R)" 0 "pause"
grep -qx 'paused=T1' $MAP/a1 && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL paused line"; }
eq "$(write_ok a1)" 0 "paused session behaves normally"
eq "$(rc $SM show T1 --session a1 --repo $R)" 1 "show: not bound"
grep -q '| session=a1 | ticket=T1 | pause | stop (DoR)$' $ST/delivery.log && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL delivery log line"; }
bind a1 '/deliver-ticket T1 answers pasted'; eq "$(write_ok a1)" 2 "re-bound by the next prompt"
eq "$(rc $SM pause T9 --reason x --session a1 --repo $R)" 1 "pause for a ticket the session is not bound to"
echo "# pause is refused once code exists (the EnterWorktree hook recorded a worktree)"
git worktree add -q .claude/worktrees/T1 -b feat-T1
jq -nc --arg cwd "$R" --arg w "$R/.claude/worktrees/T1" '{session_id:"a1",cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"EnterWorktree",tool_input:{name:"T1"},tool_response:{worktreePath:$w}}' | "$SK/hooks/worktree-guard.sh"
tf T1 7
eq "$(rc $SM pause T1 --reason x --session a1 --repo $R)" 1 "pause refused after EnterWorktree"
eq "$(rc $SM pause T1 --after-stage8 --reason x --session a1 --repo $R)" 1 "--after-stage8 refused at stage 7"
tf T1 8
eq "$(rc $SM pause T1 --after-stage8 --reason 'waiting for review' --session a1 --repo $R)" 0 "--after-stage8 allowed at stage 8"
echo "# rebind: the word after /deliver-ticket was not the ticket ID"
bind a2 '/deliver-ticket fix cart bug'
eq "$(rc $SM rebind fix WL-05 --session a2 --repo $R)" 1 "rebind needs the real ticket file first"
tf WL-05 1
eq "$(rc $SM rebind fix WL-05 --session a2 --repo $R)" 0 "rebind"
grep -qx 'ticket=WL-05' $MAP/a2 && ! grep -qx 'ticket=fix' $MAP/a2 && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL map after rebind: $(tr '\n' ' ' < $MAP/a2)"; }
grep -q '| ticket=WL-05 | rebind | token' $ST/delivery.log && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL rebind not logged"; }
bind a3 '/deliver-ticket T2 x'; tf T2 1; tf WL-06 1
eq "$(rc $SM rebind T2 WL-06 --session a3 --repo $R)" 1 "rebind refused when the old token is itself a real ticket"
echo "# ticket-state: done needs stage 8; cancelled does not; the marker (not the text) unbinds; everything is logged"
tf T3 4; bind a4 '/deliver-ticket T3'; eq "$(write_ok a4)" 2 "T3 bound"
eq "$(rc $TS done T3 --session a4 --repo $R)" 1 "done needs --reason"
eq "$(rc $TS done T3 --reason finished --session a4 --repo $R)" 1 "done refused before stage 8"
eq "$(write_ok a4)" 2 "still bound"
tf T3 8
eq "$(rc $TS done T3 --reason finished --session a4 --repo $R)" 0 "done at stage 8"
[ -e $ST/closed/T3 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL marker missing"; }
grep -q '^state: done   <!-- active | waiting | done -->$' $ST/tickets/T3.md && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL state line: $(grep '^state' $ST/tickets/T3.md)"; }
eq "$(write_ok a4)" 0 "closed ticket no longer binds"
eq "$(rc $TS done T3 --reason again --session a4 --repo $R)" 0 "second done is a no-op"
tf T4 2; bind a5 '/deliver-ticket T4'
eq "$(rc $TS cancelled T4 --reason 'not needed' --session a5 --repo $R)" 0 "cancelled without stage 8"
grep -q '| ticket=T4 | cancelled | not needed$' $ST/delivery.log && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL cancelled not logged"; }
echo "# reopen: marker renamed (nothing deleted), state active, session bound again"
eq "$(rc $TS reopen T4 --reason 'user said yes' --session a5 --repo $R)" 0 "reopen"
[ ! -e $ST/closed/T4 ] && ls $ST/closed | grep -q '^T4.reopened-' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL marker rename: $(ls $ST/closed)"; }
grep -q '^state: active' $ST/tickets/T4.md && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL state after reopen"; }
eq "$(write_ok a5)" 2 "bound after reopen"
eq "$(rc $TS reopen T4 --reason x --session a5 --repo $R)" 1 "reopen of an open ticket"
echo "# manual bind (stage 0 check 10 failed and the user said yes): only adds protection, logged"
eq "$(write_ok a6)" 0 "a6 starts unbound"
eq "$(rc $SM show T6 --session a6 --repo $R)" 1 "show: not bound"
eq "$(rc $SM bind T6 --session a6 --repo $R)" 1 "bind needs --reason"
eq "$(rc $SM bind T6 --reason 'bind hook did not fire' --session a6 --repo $R)" 0 "bind"
eq "$(write_ok a6)" 2 "bound after the manual bind"
eq "$(rc $SM show T6 --session a6 --repo $R)" 0 "show: bound"
grep -q '| session=a6 | ticket=T6 | bind | bind hook did not fire$' $ST/delivery.log && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL manual bind not logged"; }
eq "$(rc $SM bind T6 --reason again --session a6 --repo $R)" 0 "bind twice"
[ "$(grep -c '^ticket=T6$' $MAP/a6)" = 1 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL duplicate ticket line"; }
echo "# input checks"
eq "$(rc $TS done '../x' --reason r --session a5 --repo $R)" 1 "unsafe ticket id"
eq "$(rc $SM show --session '../s' --repo $R)" 1 "unsafe session id"
eq "$(rc $SM show --session a5 --repo $S/nowhere)" 1 "not a repo"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
