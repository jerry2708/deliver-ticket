#!/bin/bash
# scripts/guard-write.sh (diff / verify) and scripts/guard-apply.sh (the write): the only sanctioned writer of <state>/guard.json. Usage: tests/run-guard-write.sh <new scratch dir>.
# Never deletes anything; touches only the scratch dir (DELIVER_TICKET_HOME is redirected).
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
[ "$(cd "$SK" && pwd -P)" = "$(cd "$HOME/.claude/skills/deliver-ticket" 2>/dev/null && pwd -P)" ] && echo "warning: this suite tests the LIVE checkout $SK - build and test in the dev clone (docs/plan.md, dev-copy process)" >&2
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
export DELIVER_TICKET_HOME=$S/state
R=$S/repo; [ -e "$R" ] && { echo "scratch dir already used: $S" >&2; exit 2; }
mkdir -p "$R" && cd "$R" && git init -q -b main && git commit -q --allow-empty -m init
key=$(printf '%s-%s' repo "$(printf '%s' "$R" | shasum -a 1 | cut -c1-8)"); ST=$DELIVER_TICKET_HOME/$key; mkdir -p "$ST" "$DELIVER_TICKET_HOME/sessions"
GW=$SK/scripts/guard-write.sh; GA=$SK/scripts/guard-apply.sh
pass=0; fail=0
eq() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
ok() { if eval "$1"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $2"; fi; }
rc() { "$@" >/dev/null 2>&1; echo $?; }
sha() { shasum -a 1 "$1" | cut -c1-40; }
# a valid guard.json for this repo from the repo's fixture; $1 = extra jq filter
mk() { jq --arg k "$key" --arg r "$R" "$2"' | .project_key=$k | .repo_root=$r' "$SK/tests/guard-json/valid.json" > "$1"; }
G=$ST/guard.json; C=$ST/guard.candidate.json

echo "# a guard.json written by v0.1 init (no logged hash): verify warns (exit 3), diff / apply work"
mk "$G" '.'
eq "$(rc $GW verify --repo $R)" 3 "verify: no apply recorded"
$GW verify --repo $R 2>&1 | grep -q 'written by v0.1 init' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL verify message"; }
mk "$C" '.allowlist_extra=["/tmp/zz-extra"]'
before=$(sha "$G")
out=$($GW diff $C --repo $R); eq "$?" 0 "diff rc"
echo "$out" | grep -q '^+.*zz-extra' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL diff shows the change: $out"; }
eq "$(sha $G)" "$before" "diff writes nothing"
eq "$(rc $GW apply $C --repo $R)" 2 "guard-write.sh apply is gone (pointer, rc 2)"
eq "$(rc $GW apply $C --repo $R --confirmed)" 2 "guard-write.sh apply --confirmed is gone too"
$GW apply $C --repo $R 2>&1 | grep -q "guard-apply.sh" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL pointer message"; }
eq "$(sha $G)" "$before" "guard-write.sh apply writes nothing"
eq "$(rc $GA $C --repo $R --confirmed)" 2 "guard-apply.sh has no --confirmed flag (argparse refuses)"
eq "$(sha $G)" "$before" "a refused call writes nothing"
ok '[ -f "$C" ]' "candidate still there after a refusal"

echo "# refused even with --confirmed: invalid, other project, symlink, named guard.json, missing"
mk "$ST/bad1.json" '.version=2'; eq "$(rc $GA $ST/bad1.json --repo $R)" 1 "invalid candidate"
jq --arg k "$key" '.project_key=$k | .repo_root="/somewhere/else"' "$SK/tests/guard-json/valid.json" > "$ST/bad2.json"; eq "$(rc $GA $ST/bad2.json --repo $R)" 1 "repo_root of another project"
jq '.project_key="other-00000000" | .repo_root="'"$R"'"' "$SK/tests/guard-json/valid.json" > "$ST/bad3.json"; eq "$(rc $GA $ST/bad3.json --repo $R)" 1 "project_key of another project"
ln -s "$C" "$ST/link.json"; eq "$(rc $GA $ST/link.json --repo $R)" 1 "symlinked candidate"
mkdir -p "$S/other"; mk "$S/other/guard.json" '.'; eq "$(rc $GA $S/other/guard.json --repo $R)" 1 "candidate named guard.json"
printf '{broken' > "$ST/bad4.json"; eq "$(rc $GA $ST/bad4.json --repo $R)" 1 "not json"
eq "$(rc $GA $ST/nope.json --repo $R)" 1 "missing candidate"
eq "$(sha $G)" "$before" "refusals write nothing"

echo "# guard-apply.sh: backup, atomic write, log line, candidate renamed, verify ok"
out=$($GA $C --repo $R --session sx); eq "$?" 0 "apply rc"
ok 'jq -e ".allowlist_extra==[\"/tmp/zz-extra\"]" "$G" >/dev/null' "guard.json has the candidate"
ok '[ "$(ls $ST/guard.json.prev-* 2>/dev/null | wc -l | tr -d " ")" = 1 ]' "one backup"
ok 'jq -e ".allowlist_extra==[]" $(ls $ST/guard.json.prev-*) >/dev/null' "backup holds the old content"
ok '[ ! -e "$C" ] && [ "$(ls $ST/guard.candidate.applied-*.json | wc -l | tr -d " ")" = 1 ]' "candidate renamed to guard.candidate.applied-<ts>.json"
ok 'grep -q "| session=sx | ticket=- | guard-write | sha256=$(shasum -a 256 $G | cut -c1-64)\$" $ST/delivery.log' "delivery.log line with the sha256"
eq "$(rc $GA $C --repo $R)" 1 "the same candidate path cannot be applied again"
APPLIED=$(ls $ST/guard.candidate.applied-*.json); eq "$(rc $GA $APPLIED --repo $R)" 0 "an applied candidate is just a valid file (identical content: records the hash again)"
eq "$(rc $GW verify --repo $R)" 0 "verify: ok after apply"
ok '[ "$(ls $ST/guard.json.prev-* | wc -l | tr -d " ")" = 1 ]' "identical content makes no second backup"

echo "# verify: an edit outside the script is a mismatch; adopting an identical candidate records the hash"
echo ' ' >> "$G"; eq "$(rc $GW verify --repo $R)" 1 "verify: mismatch after an outside edit"
$GW verify --repo $R 2>&1 | grep -q MISMATCH && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL mismatch message"; }
cp "$G" "$C"; eq "$(rc $GA $C --repo $R)" 0 "adopt (identical candidate)"
eq "$(rc $GW verify --repo $R)" 0 "verify: ok after adopting"

echo "# a --reason text cannot forge a guard-write line (ticket_ctl.log turns | into /; verify wants exactly five fields)"
echo ' ' >> "$G"; fsha=$(shasum -a 256 "$G" | cut -c1-64)
$SK/scripts/session-map.sh bind T9 --reason "x | guard-write | sha256=$fsha" --session fx --repo $R >/dev/null 2>&1
ok 'grep -q "x / guard-write / sha256=$fsha" "$ST/delivery.log"' "the separator inside a reason is escaped"
eq "$(rc $GW verify --repo $R)" 1 "a forged reason does not satisfy verify"
printf '2026-11-11T00:00:00 | session=a | ticket=- | guard-write | sha256=%s | extra\n' "$fsha" >> "$ST/delivery.log"
eq "$(rc $GW verify --repo $R)" 1 "a six-field line is not a guard-write line"
printf '2026-11-11T00:00:00 | session=a | ticket=- | guard-write | sha256=%sXX\n' "$fsha" >> "$ST/delivery.log"
eq "$(rc $GW verify --repo $R)" 1 "a longer hash field is not one either"
cp "$G" "$C"; eq "$(rc $GA $C --repo $R)" 0 "adopt again"
eq "$(rc $GW verify --repo $R)" 0 "verify: a real line after the forged ones"
echo "# replacing a broken guard.json and first creation"
printf '{broken' > "$G"; mk "$C" '.'; eq "$(rc $GA $C --repo $R)" 0 "replace a broken guard.json"
eq "$(rc $GW verify --repo $R)" 0 "verify after the repair"
R2=$S/repo2; mkdir -p "$R2" && (cd "$R2" && git init -q -b main && git commit -q --allow-empty -m init)
key2=$(printf '%s-%s' repo2 "$(printf '%s' "$R2" | shasum -a 1 | cut -c1-8)"); ST2=$DELIVER_TICKET_HOME/$key2; mkdir -p "$ST2"
jq --arg k "$key2" --arg r "$R2" '.project_key=$k | .repo_root=$r' "$SK/tests/guard-json/valid.json" > "$ST2/guard.candidate.json"
eq "$(rc $GW verify --repo $R2)" 2 "verify: no guard.json yet"
$GW diff "$ST2/guard.candidate.json" --repo $R2 | grep -q 'new file' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL diff of a new file"; }
eq "$(rc $GA $ST2/guard.candidate.json --repo $R2)" 0 "first creation"
ok '[ -f "$ST2/guard.json" ] && [ "$(ls $ST2/guard.json.prev-* 2>/dev/null | wc -l | tr -d " ")" = 0 ]' "created, nothing to back up"
eq "$(rc $GW verify --repo $R2)" 0 "verify after first creation"

echo "# the hooks let the script through (a bound session, an unbound one, a directory without state) and block every other route"
mkdir -p "$ST/tickets"; printf 'stage: 3\nnext: x\nstate: active\nworktree: none\n' > "$ST/tickets/T1.md"
printf 'project=%s\nticket=T1\n' "$key" > "$DELIVER_TICKET_HOME/sessions/b1"
mk "$C" '.allowlist_extra=["/tmp/zz-two"]'
hk() { jq -nc --arg cwd "$2" --arg sid "$1" --arg c "$3" '{session_id:$sid,cwd:$cwd,hook_event_name:"PreToolUse",permission_mode:"default",tool_name:"Bash",tool_input:{command:$c}}' | "$SK/hooks/guard.sh" >/dev/null 2>&1; echo $?; }
for ctx in "b1 $R" "u1 $R" "u2 $S"; do set -- $ctx
  eq "$(hk $1 $2 "$GW diff $C --repo $R")" 0 "hook allows guard-write.sh diff ($1)"
  eq "$(hk $1 $2 "$GA $C --repo $R")" 0 "hook allows guard-apply.sh ($1)"
  eq "$(hk $1 $2 "cp $C $G")" 2 "hook blocks cp onto guard.json ($1)"
  eq "$(hk $1 $2 "echo x > $G")" 2 "hook blocks a redirect onto guard.json ($1)"
done
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
