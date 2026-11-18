#!/bin/bash
# Tests for scripts/lock-trace.sh (stage 8 trace of the plan lock) against fixture transcripts: missing sessions, unparsed calls before / after the marker,
# calls naming approvals/, marker vs current plan, the three plan hashes (shown, --sha, delivery.log) and the user turn, start records, bad input, read-only.
# Usage: tests/run-lock-trace.sh <scratch-dir>   Never deletes anything; DELIVER_TICKET_HOME and the transcript dir are redirected into the scratch dir.
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
P=$S/projects
mkdir -p "$ST/tickets" "$ST/closed" "$DELIVER_TICKET_HOME/sessions" "$DELIVER_TICKET_HOME/starts" "$P/-repo" "$R/.claude/worktrees/T1"
python3 -I -c 'import json,sys; g=json.load(open(sys.argv[1])); g.update(project_key=sys.argv[3], repo_root=sys.argv[4]); json.dump(g, open(sys.argv[2], "w"))' "$SK/tests/guard-json/valid.json" "$ST/guard.json" "$key" "$R"
LT=$SK/scripts/lock-trace.sh
pass=0; fail=0
req() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
has() { grep -qF -- "$2" "$S/out.txt" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1: missing [$2] in:"; sed 's/^/    /' "$S/out.txt"; }; }
hasnt() { grep -qF -- "$2" "$S/out.txt" && { fail=$((fail+1)); echo "FAIL $1: unexpected [$2] in:"; sed 's/^/    /' "$S/out.txt"; } || pass=$((pass+1)); }
lt() { "$LT" "$1" --repo "$R" --session "$2" --projects "$P" >"$S/out.txt" 2>&1; echo $?; }
# every run with the fixture --projects lists it: "N line(s) listed" counts it, the exit code is judged with it (1 = something listed)
tk() { printf '%s\n' "$2" > "$ST/tickets/$1.md"; }
shown() { "$SK/scripts/plan-hash.sh" "$1" --repo "$R" 2>/dev/null | awk '{print $3}'; }
approve() { "$SK/scripts/approve-plan.sh" "$1" --sha "$(shown "$1")" --repo "$R" --session "$2" >/dev/null 2>&1 || { echo "fixture: approve-plan.sh $1 failed" >&2; exit 2; }; }
start() { printf '%s\n' "$2" > "$DELIVER_TICKET_HOME/starts/$1"; }
# tx <file>: a transcript from a spec on stdin, one entry per line. Minutes are relative to now (the marker is written now):
#   C <cwd>         cwd of the following entries              U <text>   user turn          M <text>   isMeta user entry
#   A <text>        assistant text                            B <min> <command>   Bash call (ok)   E <min> <command>   Bash call (is_error)
#   W <min> <path>  Write call
TXPY=$(cat <<'PY'
import datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc)
ts = lambda m: (now + datetime.timedelta(minutes=float(m))).strftime("%Y-%m-%dT%H:%M:%S.000Z")
cwd, out, n = "/", [], 0
for l in sys.stdin.read().splitlines():
    if not l.strip():
        continue
    k, _, rest = l.partition(" ")
    n += 1
    base = {"cwd": cwd, "sessionId": "x", "timestamp": ts(0)}
    if k == "C":
        cwd = rest
    elif k in ("U", "M"):
        out.append(dict(base, type="user", isMeta=(k == "M"), message={"role": "user", "content": rest}))
    elif k == "A":
        out.append(dict(base, type="assistant", message={"role": "assistant", "content": [{"type": "text", "text": rest}]}))
    elif k in ("B", "E", "W"):
        m, _, arg = rest.partition(" ")
        name, inp = ("Write", {"file_path": arg, "content": "x"}) if k == "W" else ("Bash", {"command": arg})
        out.append(dict(base, timestamp=ts(m), type="assistant", message={"role": "assistant", "content": [{"type": "tool_use", "id": "t%d" % n, "name": name, "input": inp}]}))
        out.append(dict(base, timestamp=ts(m), type="user", message={"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t%d" % n, "content": "r", "is_error": k == "E"}]}))
        # api-request-blob repeats tool_use blocks: the scan must not count them twice
        out.append({"type": "api-request-blob", "message": {"content": [{"type": "tool_use", "id": "t%d" % n, "name": name, "input": inp}]}})
open(sys.argv[1], "w").write("".join(json.dumps(e) + "\n" for e in out))
PY
)
tx() { mkdir -p "$(dirname "$1")"; python3 -I -c "$TXPY" "$1"; }      # the spec comes on stdin

echo "# bad input: exit 2"
req "$(lt '../x' s1)" 2 "bad ticket id"
req "$(lt NOPE s1)" 2 "no ticket file"
req "$("$LT" T1 --repo "$S" --session s1 --projects "$P" >/dev/null 2>&1; echo $?)" 2 "not a git repo"

echo "# clean: hash shown, user said yes, --sha matches, delivery.log line, start record, a build after the marker -> nothing listed"
tk T1 $'# T1\n## Plan\n- one\n'
H=$(shown T1)
approve T1 s-ok
start s-ok "$R"
tx "$P/-repo/s-ok.jsonl" <<EOF
C $R
U /deliver-ticket T1
B -60 $SK/scripts/plan-hash.sh T1 --repo $R
A Plan above. plan hash $H
U yes
B -59 $SK/scripts/approve-plan.sh T1 --sha $H --repo $R --session s-ok
C $R/.claude/worktrees/T1
B 5 npm run build
B 6 make test
EOF
lt T1 s-ok >/dev/null
has "clean" "marker: sha256 $H"
has "clean" ": match"
has "clean" "approve-ok"
has "clean" "after-marker"
has "clean: only the fixture --projects is listed" "1 line(s) listed"
has "clean" "transcripts: $P"
has "clean" "projects   non-default --projects $P"
req "$(grep -cE '^(missing|session|projects|unparsed|approvals|marker|approve|start) ' "$S/out.txt")" 1 "clean: the --projects line is the only finding"
hasnt "clean: api-request-blob not read" "line 3 "

echo "# the default transcript dir is not listed (HOME points at a fake one: nothing real is read)"
mkdir -p "$S/fh/.claude/projects/-repo" && cp "$P/-repo/s-ok.jsonl" "$S/fh/.claude/projects/-repo/"
req "$(HOME=$S/fh "$LT" T1 --repo "$R" --session s-ok >"$S/out.txt" 2>&1; echo $?)" 0 "clean run, default --projects: exit 0"
has "default" "transcripts: $S/fh/.claude/projects"
has "default" "0 line(s) listed"

echo "# session ids that are not plain ids are findings, never looked up"
for bad in 'a b' '../x' 'a/b' '.hidden' 'x..y'; do
  req "$(lt T1 "$bad")" 1 "bad --session [$bad] exits 1"
  has "bad --session [$bad]" "is not a plain session id (--session): not looked up"
done
printf '2026-01-01T00:00:00 | session=../../etc | ticket=T1 | bind | x\n' >> "$ST/delivery.log"
lt T1 s-ok >/dev/null
has "bad sid in delivery.log" "'../../etc' is not a plain session id (delivery.log)"

echo "# a session in delivery.log without a transcript is listed as missing, never skipped"
printf '2026-01-01T00:00:00 | session=s-gone | ticket=T1 | bind | x\n' >> "$ST/delivery.log"
req "$(lt T1 s-ok)" 1 "missing transcript exits 1"
has "missing" "missing    s-gone: no transcript"
req "$(lt T1 s-other)" 1 "current session without a transcript"
has "missing current" "missing    s-other"

echo "# unparsed calls: before the marker counted, after it only printed"
tk T2 $'# T2\n## Plan\n- two\n'
H2=$(shown T2)
approve T2 s-un
start s-un "$R"
tx "$P/-repo/s-un.jsonl" <<EOF
C $R
U go
B -30 python3 -c "open('$R/.claude/worktrees/T1/a','w')"
E -29 cd $R/.claude/worktrees/T1 && node -e "1"
B -28 FOO=1 make build
B -27 find . -name x | xargs touch
B -26 claude -p hi
B -25 ./scripts/gen.sh
B -24 bash tools/x.sh
B -23 python3 $SK/scripts/plan_hash.py T2 --repo $R
B -22 echo make; git commit -m "make it"; ls claude-notes; find . -name x; ls | xargs echo
B -21 python3 - <<< 'print(1)'
A plan hash $H2
U yes
B -1 $SK/scripts/approve-plan.sh T2 --sha $H2 --repo $R --session s-un
B 3 python3 -c "print(1)"
EOF
req "$(lt T2 s-un)" 1 "unparsed before the marker exits 1"
for k in "[python -c] before" "[node -e, is_error] before" "[make] before" "[find + xargs/-exec] before" "[nested claude] before" "[script file] before the marker: ./scripts/gen.sh" "[script file] before the marker: bash tools/x.sh" "[interpreter stdin] before"; do has "unparsed $k" "$k"; done
hasnt "skill script is not unparsed" "plan_hash.py"
hasnt "echo make / commit message / claude-notes" "echo make"
has "after the marker printed" "after-marker"
has "after the marker printed" '[python -c] python3 -c "print(1)"'
req "$(grep -c '^unparsed' "$S/out.txt")" 8 "eight unparsed lines"

echo "# unparsed with no marker at all: every one counts, and the missing marker is listed"
tk T3 $'# T3\n## Plan\n- three\n'
start s-nm "$R"
tx "$P/-repo/s-nm.jsonl" <<EOF
C $R
B 30 npx eslint --fix .
EOF
req "$(lt T3 s-nm)" 1 "no marker exits 1"
has "no marker" "marker     no approval marker"
has "no marker: after-time call still counts" "[package script] before the marker"

echo "# any call naming approvals/"
tk T4 $'# T4\n## Plan\n- four\n'
H4=$(shown T4)
approve T4 s-ap
start s-ap "$R"
tx "$P/-repo/s-ap.jsonl" <<EOF
C $R
A plan hash $H4
U yes
B -1 $SK/scripts/approve-plan.sh T4 --sha $H4 --repo $R --session s-ap
B 2 ls $ST/approvals
W 3 $ST/approvals/T4.plan
EOF
req "$(lt T4 s-ap)" 1 "approvals/ named exits 1"
req "$(grep -c '^approvals' "$S/out.txt")" 2 "Bash and Write naming approvals/"

echo "# marker hash vs current plan: an edit after the approval is listed"
tk T4 $'# T4\n## Plan\n- four, edited\n'
lt T4 s-ap >/dev/null
has "mismatch" ": MISMATCH"
has "mismatch" "marker     the marker hash"

echo "# the three hashes and the user turn"
tk T5 $'# T5\n## Plan\n- five\n'
H5=$(shown T5)
approve T5 s-h
start s-h "$R"
tx "$P/-repo/s-h.jsonl" <<EOF
C $R
A plan hash 000000000000
U yes
B -5 $SK/scripts/approve-plan.sh T5 --sha $H5 --repo $R --session s-h
A plan hash $H5
M <system-reminder>not a user turn</system-reminder>
B -4 $SK/scripts/approve-plan.sh T5 --sha $H5 --repo $R --session s-h
A plan hash $H5
U [Request interrupted by user]
E -3 $SK/scripts/approve-plan.sh T5 --sha $H5 --repo $R --session s-h
EOF
tx "$P/-repo/s-h/subagents/agent-1.jsonl" <<EOF
A plan hash $H5
U a subagent's prompt is not the user's yes
B -2 $SK/scripts/approve-plan.sh T5 --sha $H5 --repo $R --session s-h
EOF
req "$(lt T5 s-h)" 1 "hash problems exit 1"
has "sha vs shown" "differs from the hash shown 000000000000"
req "$(grep -c 'approved without a user turn' "$S/out.txt")" 3 "isMeta, an interrupt and a subagent's prompt are not a user turn"
has "is_error call tagged" "(is_error)"
has "subagent" "ran in a subagent"
# T6: approved by a call the transcripts do not have; T7: a call with no plan hash line before it and no delivery.log line (logged under another ticket)
tk T6 $'# T6\n## Plan\n- six\n'
approve T6 s-x
tk T7 $'# T7\n## Plan\n- seven\n'
H7=$(shown T7)
start s-y "$R"
tx "$P/-repo/s-y.jsonl" <<EOF
C $R
U yes
B -1 $SK/scripts/approve-plan.sh T7 --sha $H7 --repo $R --session s-y
EOF
tx "$P/-repo/s-x.jsonl" <<EOF
C $R
U hi
EOF
start s-x "$R"
req "$(lt T6 s-x)" 1 "log line without a call exits 1"
has "log without call" "no approve-plan.sh call for it in the scanned transcripts"
req "$(lt T7 s-y)" 1 "call without hash line / log line exits 1"
has "no hash shown" "no \`plan hash\` line in Claude's text before it"
has "no log line" "no delivery.log plan-approve line with sha256=$H7"

echo "# start records"
tk T8 $'# T8\n## Plan\n- eight\n'
H8=$(shown T8)
approve T8 s-st
tx "$P/-repo/s-st.jsonl" <<EOF
C $R
A plan hash $H8
U yes
B -1 $SK/scripts/approve-plan.sh T8 --sha $H8 --repo $R --session s-st
C $R/.claude/worktrees/T1
U next
C $S
U elsewhere
EOF
req "$(lt T8 s-st)" 1 "no start record exits 1"
has "no record" "start      s-st: no starts/s-st record"
start s-st "$R"
lt T8 s-st >/dev/null
has "cwd outside" "transcript cwd(s) outside it and outside the worktrees: $S"
hasnt "worktree cwd is fine" "worktrees/T1,"
ln -s "$S/elsewhere" "$DELIVER_TICKET_HOME/starts/s-ln"
tx "$P/-repo/s-ln.jsonl" <<EOF
C $R
U hi
EOF
lt T8 s-ln >/dev/null
has "symlinked record ignored" "no starts/s-ln record (or a symlink)"

echo "# read-only: the state root and the transcripts are unchanged by every run above and by one more"
snap() { (cd "$S" && find state projects -print0 | sort -z | xargs -0 shasum 2>/dev/null; find state projects | sort) | shasum; }
b=$(snap); lt T5 s-h >/dev/null; lt T2 s-un >/dev/null; req "$(snap)" "$b" "lock-trace writes nothing"

echo "pass=$pass fail=$fail"; [ $fail = 0 ]
