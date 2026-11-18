#!/bin/bash
# Tests for scripts/approve-plan.sh (the gate writer of <state>/approvals/<ID>.plan) and scripts/plan_lock.py (hash + safe marker read).
# Usage: tests/run-approve-plan.sh <scratch-dir>   Never deletes anything; DELIVER_TICKET_HOME is redirected into the scratch dir.
set -u
S=${1:?scratch dir (must be new or empty)}
SK=$(cd "$(dirname "$0")/.." && pwd)
[ "$(cd "$SK" && pwd -P)" = "$(cd "$HOME/.claude/skills/deliver-ticket" 2>/dev/null && pwd -P)" ] && echo "warning: this suite tests the LIVE checkout $SK - build and test in the dev clone (docs/plan.md, dev-copy process)" >&2
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
export DELIVER_TICKET_HOME=$S/state
R=$S/repo
[ -e "$R" ] && { echo "scratch dir already used: $S (pick a new one; the script never deletes anything)" >&2; exit 2; }
mkdir -p "$R" && cd "$R" && git init -q -b main && git commit -q --allow-empty -m init
key=$(printf '%s-%s' repo "$(printf '%s' "$R" | shasum -a 1 | cut -c1-8)")
ST=$DELIVER_TICKET_HOME/$key
mkdir -p "$ST/tickets" "$ST/closed" "$DELIVER_TICKET_HOME/sessions"
python3 -I -c 'import json,sys; g=json.load(open(sys.argv[1])); g.update(project_key=sys.argv[3], repo_root=sys.argv[4]); json.dump(g, open(sys.argv[2], "w"))' "$SK/tests/guard-json/valid.json" "$ST/guard.json" "$key" "$R"
AP=$SK/scripts/approve-plan.sh
pass=0; fail=0
req() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
shown() { "$SK/scripts/plan-hash.sh" "$1" --repo "$R" 2>/dev/null | awk '{print $3}'; }      # the 12 hex digits stage 2 shows under the plan
# ap <ID> [args]: approve with the current plan hash as --sha (what the user was shown), unless the arguments are --rework ...; apx: exactly the given arguments
ap() { local t=$1; shift; case " $* " in *" --rework "*) "$AP" "$t" "$@" --repo "$R" --session s1 >"$S/out.txt" 2>&1 ;; *) "$AP" "$t" --sha "$(shown "$t")" "$@" --repo "$R" --session s1 >"$S/out.txt" 2>&1 ;; esac; echo $?; }
apx() { "$AP" "$@" --repo "$R" --session s1 >"$S/out.txt" 2>&1; echo $?; }
tk() { printf '%s\n' "$2" > "$ST/tickets/$1.md"; }
# approved <ID>: exit 0 when plan_lock says the plan is approved
approved() { python3 -I - "$SK/scripts" "$ST" "$1" <<'PY'
import sys
sys.path.insert(0, sys.argv[1]); import plan_lock
ok, why = plan_lock.plan_approved(sys.argv[2], sys.argv[3], open(sys.argv[2] + "/tickets/" + sys.argv[3] + ".md").read())
print(ok, why)
sys.exit(0 if ok else 1)
PY
}
ok() { approved "$1" >/dev/null 2>&1 && echo yes || echo no; }

echo "# refusals: no ticket, no / empty / doubled plan section, bad id, closed ticket"
req "$(ap T1)" 2 "no ticket file"
tk T1 $'# T1\n## Goal\nx\n## Build log\n'
req "$(ap T1)" 2 "no ## Plan section"
tk T1 $'# T1\n## Plan\n\n   \n## Build log\n'
req "$(ap T1)" 2 "empty plan section"
tk T1 $'# T1\n## Plan\n- step 1\n## Plan\n- step 2\n'
req "$(ap T1)" 2 "two ## Plan headings"
req "$(ap ../x)" 2 "id with .."
req "$(ap 'T1 x')" 2 "id with a space"
[ ! -e "$ST/approvals" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL a refusal created approvals/"; }
tk T9 $'# T9\n## Plan\n- s\n'
printf 'x\n' > "$ST/closed/T9"
req "$(ap T9)" 2 "closed ticket"

echo "# --sha: the plan the user was shown is the plan that gets locked"
tk TS $'# TS\n## Plan\n- one\n- two\n'
h=$(shown TS)
[[ "$h" =~ ^[0-9a-f]{12}$ ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL plan-hash.sh output [$h]"; }
req "$("$SK/scripts/plan-hash.sh" TS --repo "$R" | cut -c1-10)" "plan hash " "plan-hash.sh output format"
req "$(apx TS)" 2 "no --sha: refused"
req "$(apx TS --sha 000000000000)" 2 "wrong --sha: refused"
req "$(apx TS --sha "${h:0:11}")" 2 "short --sha: refused"
req "$(apx TS --sha "$(echo "$h" | tr a-f A-F)")" 2 "upper-case --sha: refused"
[ ! -e "$ST/approvals/TS.plan" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL a refused approval wrote a marker"; }
tk TS $'# TS\n## Plan\n- one\n- two\n- three (added after the user said yes)\n'
req "$(apx TS --sha "$h")" 2 "plan edited after plan-hash.sh was shown: refused"
grep -q "$(shown TS)" "$S/out.txt" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL the refusal does not name the new hash"; cat "$S/out.txt"; }
req "$(ok TS)" no "and not approved"
req "$(apx TS --sha "$(shown TS)")" 0 "the sha of the CURRENT plan is accepted"
req "$(ok TS)" yes "approved"
grep -q "ticket=TS | plan-approve | sha256=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import plan_lock; print(plan_lock.plan_hash(open(sys.argv[2]).read())[0])' "$SK/scripts" "$ST/tickets/TS.md")" "$ST/delivery.log" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL delivery.log does not hold the full hash"; }
req "$("$SK/scripts/plan-hash.sh" NOPE --repo "$R" >/dev/null 2>&1; echo $?)" 2 "plan-hash.sh: no ticket file"
tk TD $'# TD\n## Plan\n- a\n## Plan\n- b\n'
req "$("$SK/scripts/plan-hash.sh" TD --repo "$R" >/dev/null 2>&1; echo $?)" 2 "plan-hash.sh: two ## Plan headings"
req "$("$SK/scripts/plan-hash.sh" '../x' --repo "$R" >/dev/null 2>&1; echo $?)" 2 "plan-hash.sh: bad id"
echo "# approve, then the hash follows the plan section only"
tk T1 $'# T1\n## Goal\ng\n## Plan\n- step 1\n- step 2   \n\n## Plan check\n| AC | step |\n## Build log\nlog\n'
req "$(ok T1)" no "not approved before approving"
req "$(ap T1)" 0 "approve"
req "$(ok T1)" yes "approved after approve-plan"
M=$ST/approvals/T1.plan
[ -f "$M" ] && grep -q '^sha256=[0-9a-f]\{64\}$' "$M" && grep -q '^approved=' "$M" && grep -q '^session=s1$' "$M" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL marker content"; cat "$M"; }
[ "$(stat -f %Lp "$M" 2>/dev/null || stat -c %a "$M")" = 600 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL marker mode"; }
ls "$ST/approvals" | grep -q 'tmp' && { fail=$((fail+1)); echo "FAIL leftover temp file"; } || pass=$((pass+1))
grep -q 'ticket=T1 | plan-approve | sha256=' "$ST/delivery.log" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL delivery.log line"; tail -2 "$ST/delivery.log"; }
tk T1 $'# T1\n## Goal\nCHANGED\n## Plan\n- step 1\n- step 2   \n\n## Plan check\n| AC | step | more |\n## Build log\nmore log\n'
req "$(ok T1)" yes "an edit outside the plan section keeps the approval"
printf '# T1\r\n## Goal\r\ng\r\n## Plan\r\n- step 1  \r\n- step 2\r\n\r\n\r\n## Build log\r\n' > "$ST/tickets/T1.md"
req "$(ok T1)" yes "CRLF, trailing blanks and blank lines at the end do not matter"
tk T1 $'# T1\n## Plan\n- step 1\n- step 2 (changed)\n'
req "$(ok T1)" no "an edit of the plan text closes the lock"
tk T1 $'# T1\n## Plan\n- step 1\n- step 2\n- step 3\n'
req "$(ok T1)" no "an added step closes the lock"
tk T1 $'# T1\n## Plan\n- step 1\n- step 2\n## Plan\n- sneaked in\n'
req "$(ok T1)" no "a second ## Plan heading is not approved (fail-closed)"
req "$(ap T1)" 2 "and cannot be approved"
echo "## a heading inside a code fence does not end the section"
printf '# T1\n## Plan\n- step 1\n```\n## not a heading\n```\n- step 2\n## Build log\n' > "$ST/tickets/T1.md"
req "$(ap T1)" 0 "approve a plan with a fenced heading"
printf '# T1\n## Plan\n- step 1\n```\n## not a heading\n```\n- step 2 EDITED\n## Build log\n' > "$ST/tickets/T1.md"
req "$(ok T1)" no "an edit after the fenced heading still re-locks"

echo "# symlinks and odd objects (a pre-planted link must not redirect the writer or the reader); each case has its own repo and state dir, nothing is moved"
fresh() { # fresh <name>: a new repo + state dir with ticket T2 (sets R, ST)
  R=$S/$1; mkdir -p "$R" && git -C "$R" init -q -b main && git -C "$R" commit -q --allow-empty -m init
  key=$(printf '%s-%s' "$1" "$(printf '%s' "$R" | shasum -a 1 | cut -c1-8)"); ST=$DELIVER_TICKET_HOME/$key
  mkdir -p "$ST/tickets" "$ST/closed"; printf '# T2\n## Plan\n- a\n' > "$ST/tickets/T2.md"; }
mkdir -p "$S/elsewhere"
fresh p1; ln -s "$S/elsewhere" "$ST/approvals"
req "$(ap T2)" 2 "approvals/ is a symlink: the writer refuses"
[ -z "$(ls -A "$S/elsewhere")" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL the writer wrote through the symlink"; ls -A "$S/elsewhere"; }
req "$(ok T2)" no "approvals/ is a symlink: the reader says not approved"
printf 'sha256=%s\napproved=x\nsession=x\n' "$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import plan_lock; print(plan_lock.plan_hash(open(sys.argv[2]).read())[0])' "$SK/scripts" "$ST/tickets/T2.md")" > "$S/elsewhere/T2.plan"
req "$(ok T2)" no "a VALID marker reachable only through a symlinked approvals/ is not trusted"
req "$(approved T2 | cut -c1-6)" "False " "...and the reader reports a problem"
fresh p2; mkdir "$ST/approvals"; printf 'sha256=%s\n' "$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import plan_lock; print(plan_lock.plan_hash(open(sys.argv[2]).read())[0])' "$SK/scripts" "$ST/tickets/T2.md")" > "$S/elsewhere/T2.plan"
ln -s "$S/elsewhere/T2.plan" "$ST/approvals/T2.plan"
before=$(shasum "$S/elsewhere/T2.plan")
req "$(ap T2)" 2 "marker is a symlink: the writer refuses"
[ "$(shasum "$S/elsewhere/T2.plan")" = "$before" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL the symlink target was changed"; }
req "$(ok T2)" no "marker is a symlink (to a valid marker): the reader says not approved"
fresh p3; mkdir -p "$ST/approvals/T2.plan"
req "$(ap T2)" 2 "marker is a directory: the writer refuses"
req "$(ok T2)" no "marker is a directory: not approved"
fresh p4; : > "$ST/approvals"
req "$(ap T2)" 2 "approvals is a regular file: the writer refuses"
req "$(ok T2)" no "approvals is a regular file: not approved"
fresh p5; mkdir "$ST/approvals"
req "$(ap T2)" 0 "a plain approvals/ directory works"
req "$(ok T2)" yes "and reads back"
echo "## --rework through a symlinked approvals/ renames nothing"
fresh p6; ln -s "$S/elsewhere" "$ST/approvals"; : > "$S/elsewhere/T2.plan"
req "$(ap T2 --rework --reason x)" 2 "--rework refuses a symlinked approvals/"
[ -e "$S/elsewhere/T2.plan" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL --rework renamed through the link"; }
R=$S/repo; ST=$DELIVER_TICKET_HOME/$(printf '%s-%s' repo "$(printf '%s' "$R" | shasum -a 1 | cut -c1-8)")

echo "# --rework retires the marker (renamed, never deleted)"
tk T3 $'# T3\n## Plan\n- a\n'
req "$(ap T3)" 0 "approve T3"
req "$(ok T3)" yes "T3 approved"
req "$(ap T3 --rework)" 2 "--rework needs --reason"
req "$(ap T3 --rework --reason 'MR comments change the plan')" 0 "--rework"
req "$(ok T3)" no "no longer approved"
ls "$ST/approvals" | grep -q '^T3.plan.rework-' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL retired marker not kept"; ls "$ST/approvals"; }
grep -q 'ticket=T3 | plan-rework | MR comments change the plan' "$ST/delivery.log" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL rework log line"; }
req "$(ap T3 --rework --reason again)" 0 "--rework with no marker is a no-op"
req "$(ap T3)" 0 "approve again"
req "$(ok T3)" yes "approved again"

echo "# ticket-state reopen retires the marker too"
ts() { "$SK/scripts/ticket-state.sh" "$@" --reason test --session s1 --repo "$R" >"$S/ts-out.txt" 2>&1; echo $?; }
req "$(ts cancelled T3)" 0 "cancel T3 ($(head -c 200 "$S/ts-out.txt" 2>/dev/null))"
req "$(ap T3)" 2 "approving a closed ticket is refused"
req "$(ts reopen T3)" 0 "reopen T3 ($(head -c 200 "$S/ts-out.txt" 2>/dev/null))"
req "$(ok T3)" no "a reopened ticket is not approved"
ls "$ST/approvals" | grep -q '^T3.plan.reopened-' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL reopened marker not kept"; ls "$ST/approvals"; }
req "$(ap T3)" 0 "approve after reopen"

echo "# nothing in approvals/ is ever deleted by the writer"
n=$(ls -A "$ST/approvals" | wc -l | tr -d ' ')
req "$(ap T3)" 0 "approve T3 once more (replaces the marker atomically)"
[ "$(ls -A "$ST/approvals" | wc -l | tr -d ' ')" = "$n" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL file count changed on re-approve"; }

echo "pass=$pass fail=$fail"; [ $fail = 0 ]
