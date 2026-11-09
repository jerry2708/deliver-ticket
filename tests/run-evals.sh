#!/bin/bash
# Phase-6 eval tooling: evals_lib.py (truth.json, inputs), run-evals.py (runner), score-evals.py (scorer) against a FAKE `claude`
# (python script in the scratch dir). No real session is started and nothing outside the scratch dir is written.
# Usage: tests/run-evals.sh <new scratch dir>
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
[ -z "$(ls -A "$S")" ] || { echo "scratch dir not empty" >&2; exit 2; }
pass=0; fail=0
eq() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
has() { printf '%s' "$1" | grep -q -- "$2" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: missing [$2] in: $(printf '%s' "$1" | head -c 400)"; }; }
hasnt() { printf '%s' "$1" | grep -q -- "$2" && { fail=$((fail+1)); echo "FAIL $3: unexpected [$2]"; } || pass=$((pass+1)); }
NOTES=/Users/huynhminh/Desktop/Work/copilot-kit-training/docs/training-v2
PJ="--jobs r1-WL-02-intake,r1-RETRO-5-intake --scope all"      # the old pilot pair: one go row (WL-02) and one stop (DoR) row
RUN="python3 $SK/scripts/run-evals.py"
SCORE="python3 $SK/scripts/score-evals.py"

echo "# evals_lib: truth.json is derived from sample-tiers.md; inputs are verbatim from the notes"
python3 "$SK/scripts/evals_lib.py" make-truth --check >/dev/null; eq "$?" 0 "evals/truth.json up to date"
out=$(python3 - "$SK" "$NOTES" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import evals_lib as L
N = sys.argv[2]
t = L.load_truth()
ok = lambda c, m: print("PASS" if c else "FAIL lib: " + m)
rows = {r["id"]: r for r in t["rows"]}
ok(len(t["rows"]) == 14, "14 rows")
ok(len(L.jobs_for(t, 3)) == 45 and len(L.jobs_for(t, 3, scope="all")) == 63, "45 jobs for 3 rounds in v0.1 scope, 63 with all")
ok(not any(j["ticket"].startswith("WL") for j in L.jobs_for(t, 3)) and all(j["ticket"].startswith("WL") for j in L.jobs_for(t, 3, scope="6b")), "WL rows are phase 6b only")
ok([j["id"] for j in L.select_jobs(t, 1, pilot=True)] == L.PILOT == ["r1-RETRO-5-intake", "r1-RETRO-8-intake"], "pilot = RETRO-5 intake + RETRO-8 intake")
ok(sum(1 for r in t["rows"] if r["intake"] == "stop (DoR)") == 7 and rows["RETRO-8"]["intake"] == "split", "7 DoR rows, 1 split")
ok(rows["RETRO-7"]["tier"] == "C" and rows["RETRO-5"]["tier"] == "B" and rows["WL-01"]["tier"] == "C", "tiers of rows 13, 11, 1")
ok({p["name"]: p["tier"] for p in rows["RETRO-8"]["parts"]} == {"env-check skill": "B", "Stop hook": "C", "verify-report skill": "B"}, "split parts")
cap = open(N + "/capstone/tickets.md").read()
ok(L.intake_text(rows["WL-02"], N) == L.capstone_section(cap, "WL-02") and L.intake_text(rows["WL-02"], N).startswith("## WL-02"), "WL-02 text = its section")
ok("## WL-03" not in L.intake_text(rows["WL-02"], N), "section stops at the next heading")
ok(L.intake_text(rows["RETRO-5"], N) == "Retro #5 - `purchase-plan-card` crashes when the result has no `checkout`", "retro #5 text is the title only")
ok(L.intake_text(rows["RETRO-4"], N).count("pre-existing") == 0, "no evidence column in the retro text")
f = L.fixture_text(rows["RETRO-7"], N)
ok("Goal: The agent's prompt" in f and "\nAC2:" in f and "eval" not in f.lower(), "fixture 7 has goal + ACs and no word 'eval'")
f3 = L.fixture_text(rows["RETRO-3"], N)
ok("Open question: which field" in f3 and "eval" not in f3.lower(), "fixture 3 note without 'for the eval'")
ok(not any(r["fixture"] for r in t["rows"] if r["intake"] != "stop (DoR)"), "fixtures only on DoR rows")
PY
)
pass=$((pass+$(echo "$out" | grep -c '^PASS'))); fail=$((fail+$(echo "$out" | grep -c '^FAIL'))); echo "$out" | grep '^FAIL'

# ---- fake claude
cat > "$S/fake-claude.py" <<'PY'
#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
prompt = args[-1] if args else ""
home = os.environ.get("DELIVER_TICKET_HOME", "")
mode = os.environ.get("FAKE_MODE", "ok")
open(os.environ["FAKE_LOG"], "a").write("%s|%s|%s|%s\n" % (home, os.environ.get("CLAUDE_CODE_DISABLE_AUTO_MEMORY"), os.getcwd(), " ".join(args[:-1])))
def emit(o): print(json.dumps(o), flush=True)
if "--output-format" in args and args[args.index("--output-format") + 1] == "json":      # the grader
    emit({"type": "result", "result": os.environ.get("FAKE_GRADE", '{"covers_all": true, "missing": [], "superfluous": [], "notes": "ok"}')}); sys.exit(0)
tid = prompt.split("\n")[0].split()[1]
sid = "sess-%s-%d" % (tid, os.getpid())
emit({"type": "system", "subtype": "init", "session_id": sid})
if mode == "fail_exit": sys.exit(1)
if mode == "hang": time.sleep(60)
if mode == "noresult": sys.exit(0)
if mode == "touchrepo": open("touched.txt", "w").write("x")
if mode == "realstate": open(os.environ["FAKE_REAL"] + "/touched", "w").write("x")
if mode == "bound":
    os.makedirs(os.environ["FAKE_REAL_HOME"] + "/sessions", exist_ok=True); open(os.environ["FAKE_REAL_HOME"] + "/sessions/" + sid, "w").write("x")
if mode == "limit":
    emit({"type": "result", "subtype": "error_during_execution", "is_error": True, "session_id": sid, "result": "Claude AI usage limit reached"}); sys.exit(1)
dor = tid.startswith("RETRO") and tid != "RETRO-8" and "Goal:" not in prompt
verdict = os.environ.get("FAKE_VERDICT") or ("split" if tid == "RETRO-8" else "stop (DoR)" if dor else "go")
tier = os.environ.get("FAKE_TIER", "B")
key = [d for d in os.listdir(home)][0]
os.makedirs("%s/%s/tickets" % (home, key), exist_ok=True)
ac = "- AC1: Given X, when Y, then Z" if os.environ.get("FAKE_AC") == "unmarked" else "- AC1: Given X, then Z. PROPOSED – not in source"
ticket = "# %s\nworktree: %s\n\n## Acceptance criteria\n%s\n\n## Intake\n- Verdict: %s (DoR met)\n\n## Classification\n| Category | yes/no/unknown | Source |\n|---|---|---|\n| auth | no | x |\n| payment | unknown | y |\n" % (tid, os.environ.get("FAKE_WORKTREE", "none"), ac if dor else "- AC1: Given X, then Z", verdict)
if not dor and verdict != "split":
    ticket += "Provisional tier **%s**.\n" % tier
open("%s/%s/tickets/%s.md" % (home, key, tid), "w").write(ticket)
if dor:
    vi = os.environ.get("FAKE_LANG") == "vi"
    q = "# %s %s\n" % ("Câu hỏi cho chủ ticket - ticket" if vi else "Questions for the owner - ticket", tid)
    for i in (1, 2, 3):
        if vi:
            q += "**%d. Mục tiêu, kết quả mong đợi và thực tế, bước tái hiện và tiêu chí chấp nhận kiểm thử được %d là gì?**\nVì sao: build.\nTham chiếu: %s, AC1.\nLựa chọn:\n- A (khuyến nghị): x\n- B: y\n" % (i, i, tid)
        else:
            q += "**%d. What is the goal, the expected and actual result, the repro steps and a testable acceptance criterion %d?**\nWhy it matters: build.\nReference: %s, AC1.\nOptions:\n- A (recommended): x\n- B: y\n" % (i, i, tid)
    if os.environ.get("FAKE_MANYQ"):
        q += "".join("**%d. extra question\nWhy: x\nReference: y\nOptions:\n- A (r): x\n- B: y\n" % k for k in (4, 5, 6))
    if not os.environ.get("FAKE_NOQFILE"):
        open("%s/%s/tickets/%s-questions.md" % (home, key, tid), "w").write(q)
    # the gate itself is numbered 1-7: those numbers are not questions
    final = "".join("**%d. Gate section %d**\n" % (k, k) for k in range(1, 8)) + ("Verdict: stop (DoR)\n")
    if os.environ.get("FAKE_NAMETIER"):
        final += "Provisional tier B\n"
elif verdict == "split":
    final = "Verdict: split\n- env-check skill: tier B\n- Stop hook: tier %s\n- verify-report skill: tier B\n" % os.environ.get("FAKE_STOPTIER", "C")
else:
    final = "Verdict: %s. Provisional tier %s." % (verdict, tier)
proj = os.environ["FAKE_PROJECTS"] + "/p"
os.makedirs(proj, exist_ok=True)
with open("%s/%s.jsonl" % (proj, sid), "w") as f:
    f.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "a", "name": "Read", "input": {"file_path": "%s/%s/tickets/%s.md" % (home, key, tid)}}]}}) + "\n")
    if os.environ.get("FAKE_LEAK"):
        f.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "b", "name": "Bash", "input": {"command": "cat %s/../../r9-other.a1/home/x" % home.replace("/home", "") + "/../dt-runs/x"}}]}}) + "\n")
if os.environ.get("FAKE_WTREAD") or os.environ.get("FAKE_BRANCH") or os.environ.get("FAKE_WTLIST"):
    cmd = {"FAKE_WTREAD": "git -C /r/.claude/worktrees/RETRO-5 log", "FAKE_BRANCH": "git log fix/retro-5-x", "FAKE_WTLIST": "git worktree list"}
    k = [x for x in cmd if os.environ.get(x)][0]
    with open("%s/%s.jsonl" % (proj, sid), "a") as f:
        f.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "c", "name": "Bash", "input": {"command": cmd[k]}}]}}) + "\n")
emit({"type": "result", "subtype": "success", "is_error": False, "session_id": sid, "result": final, "duration_ms": 1234, "num_turns": 3, "total_cost_usd": 0.5,
      "usage": {"input_tokens": 10, "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 100, "output_tokens": 50}})
PY
chmod +x "$S/fake-claude.py"
export FAKE_LOG=$S/calls.log FAKE_PROJECTS=$S/projects DT_EVAL_CLAUDE=$S/fake-claude.py
mkdir -p "$S/state/proj-key/tickets" "$S/state/proj-key/evidence"
for f in config.md config.local.md project.md; do echo "x $f" > "$S/state/proj-key/$f"; done
echo '{"repo_root":"x"}' > "$S/state/proj-key/guard.json"; echo decoy > "$S/state/proj-key/tickets/OLD.md"; echo decoy > "$S/state/proj-key/evidence/e.txt"
export FAKE_REAL=$S/state/proj-key FAKE_REAL_HOME=$S/state
mkrepo() { mkdir -p "$1" && git -C "$1" init -q && git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; }
# each scenario gets its own eval root and repo (nothing is deleted between scenarios)
scen() { n=$1; export DT_EVAL_ROOT=$S/er_$n; REPO=$S/repo_$n; mkrepo "$REPO"; : > "$FAKE_LOG"; cp -R "$S/state" "$S/state_$n"; export FAKE_REAL=$S/state_$n/proj-key FAKE_REAL_HOME=$S/state_$n; COMMON="--notes $NOTES --repo $REPO --source-state $S/state_$n/proj-key"; }
before=$(cd "$S/state" && find . -type f | sort | xargs shasum | shasum)

echo "# runner: pilot, isolation, seeding"
scen a
out=$($RUN run $PJ $COMMON); eq "$?" 0 "pilot run rc"
has "$out" "running 2 (serial)" "2 pilot jobs"
eq "$(ls "$DT_EVAL_ROOT/runs" | sort | tr '\n' ' ')" "r1-RETRO-5-intake.a1 r1-WL-02-intake.a1 " "attempt dirs"
H=$DT_EVAL_ROOT/runs/r1-WL-02-intake.a1/home
eq "$(ls "$H/proj-key" | grep -v '^tickets$' | sort | tr '\n' ' ')" "config.local.md config.md guard.json project.md " "home seeded with the 4 files only"
[ ! -e "$H/proj-key/evidence" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL evidence dir copied into the run home"; }
[ ! -e "$H/proj-key/tickets/OLD.md" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL old ticket copied into the run home"; }
l=$(head -1 "$FAKE_LOG")
has "$l" "^$H|1|$REPO|-p --permission-mode auto --output-format stream-json --verbose" "env + cwd + flags of the claude call"
has "$(cat $DT_EVAL_ROOT/runs/r1-WL-02-intake.a1/prompt.txt)" '^/deliver-ticket WL-02 ## WL-02' "WL prompt = ID + section"
has "$(cat $DT_EVAL_ROOT/runs/r1-RETRO-5-intake.a1/prompt.txt)" '^/deliver-ticket RETRO-5 Retro #5 - `purchase-plan-card` crashes when the result has no `checkout`$' "retro prompt = ID + title only"
eq "$(python3 -c "import json;m=json.load(open('$DT_EVAL_ROOT/runs/r1-WL-02-intake.a1/meta.json'));print(m['status'],m['attempt'],m['safety'],m['result']['usage']['output_tokens'])")" "done 1 [] 50" "meta of a done run"
out=$($RUN run $PJ $COMMON); has "$out" "0 not done" "second run does nothing"; eq "$(ls "$DT_EVAL_ROOT/runs" | wc -l | tr -d ' ')" 2 "no new attempt dir"
out=$($RUN status $PJ $COMMON); has "$out" "done 2, failed 0, pending 0" "status"; has "$out" "cost reported by claude: \$1.00" "status cost"
[ -f "$DT_EVAL_ROOT/inputs/RETRO-5.fixture.txt" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL prepare did not write the fixture input"; }

echo "# runner: failure stops the queue; the next call continues from a fresh home"
scen b
out=$(FAKE_MODE=fail_exit $RUN run $PJ $COMMON); eq "$?" 3 "failed session -> rc 3"
has "$out" "STOPPED: r1-WL-02-intake failed" "stopped on the first failure"
[ ! -e "$DT_EVAL_ROOT/runs/r1-RETRO-5-intake.a1" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL the queue went on after a failure"; }
has "$(cat $DT_EVAL_ROOT/runs/r1-WL-02-intake.a1/meta.json)" '"status": "failed"' "attempt 1 failed"
has "$(cat $DT_EVAL_ROOT/runs/r1-WL-02-intake.a1/meta.json)" 'exit code 1' "reason recorded"
out=$($RUN run $PJ $COMMON); eq "$?" 0 "continue -> rc 0"
eq "$(ls "$DT_EVAL_ROOT/runs" | sort | tr '\n' ' ')" "r1-RETRO-5-intake.a1 r1-WL-02-intake.a1 r1-WL-02-intake.a2 " "a1 kept, a2 added from a fresh home"
[ -d "$DT_EVAL_ROOT/runs/r1-WL-02-intake.a1/home" ] && [ -f "$DT_EVAL_ROOT/runs/r1-WL-02-intake.a1/stream.jsonl" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL partial output of a1 not kept"; }
eq "$(ls "$DT_EVAL_ROOT/runs/r1-WL-02-intake.a2/home/proj-key/tickets" | tr '\n' ' ')" "WL-02.md " "a2 home holds only its own ticket"
out=$($SCORE score $PJ --eval-root $DT_EVAL_ROOT --projects $FAKE_PROJECTS); has "$out" "FAILED attempts (partial output kept, never scored)" "scorer lists the failed attempt"; has "$out" "r1-WL-02-intake a1: exit code 1" "failed attempt named"
scen c
out=$(FAKE_MODE=limit $RUN run $PJ $COMMON); eq "$?" 3 "limit -> rc 3"; has "$(cat $DT_EVAL_ROOT/runs/r1-WL-02-intake.a1/meta.json)" 'limit_or_api' "limit-like text labelled"
scen d
FAKE_MODE=noresult $RUN run $PJ $COMMON >/dev/null; eq "$?" 3 "no result event -> rc 3"; has "$(cat $DT_EVAL_ROOT/runs/r1-WL-02-intake.a1/meta.json)" 'no result event' "reason: no result event"
scen e
t0=$(date +%s); FAKE_MODE=hang $RUN run $PJ --timeout 2 $COMMON >/dev/null; eq "$?" 3 "timeout -> rc 3"; t1=$(date +%s)
[ $((t1-t0)) -lt 30 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL timeout did not kill the session ($((t1-t0))s)"; }
has "$(cat $DT_EVAL_ROOT/runs/r1-WL-02-intake.a1/meta.json)" 'timeout after 2s' "reason: timeout"
scen f
$RUN run $PJ --batch 1 $COMMON >/dev/null; eq "$?" 0 "batch 1 rc"; eq "$(ls "$DT_EVAL_ROOT/runs" | wc -l | tr -d ' ')" 1 "batch 1 ran one job"
$RUN run $PJ --batch 1 $COMMON >/dev/null; eq "$(ls "$DT_EVAL_ROOT/runs" | wc -l | tr -d ' ')" 2 "the next call continued with the second job"

echo "# runner: safety changes stop the queue"
scen g; FAKE_MODE=touchrepo $RUN run $PJ $COMMON >/dev/null; eq "$?" 4 "main checkout touched -> rc 4"
has "$(cat $DT_EVAL_ROOT/runs/r1-WL-02-intake.a1/meta.json)" 'main checkout changed' "repo change recorded"
scen h; FAKE_MODE=realstate $RUN run $PJ $COMMON >/dev/null; eq "$?" 4 "real project state touched -> rc 4"
scen i; FAKE_MODE=bound $RUN run $PJ $COMMON >/dev/null; eq "$?" 4 "session bound in the real state root -> rc 4"
scen j; export DT_EVAL_ROOT=$S/state_j/inside; $RUN list $PJ $COMMON >/dev/null 2>&1; eq "$?" 2 "eval root inside the real state root refused"

echo "# scorer: mechanics on fake runs"
sc() { $SCORE score $PJ --json --eval-root "$DT_EVAL_ROOT" --projects "$FAKE_PROJECTS" 2>/dev/null; }
field() { python3 -c "import json,sys;d=json.load(sys.stdin);r=[x for x in d['results'] if x['job']=='$1'][0];print($2)"; }
scen k
$RUN run $PJ $COMMON >/dev/null
eq "$(sc | field r1-WL-02-intake "r['status'],r['verdict'],r['tier'],r['unknown']")" "ok go B 1" "WL-02 intake ok"
eq "$(sc | field r1-RETRO-5-intake "r['status']")" "review" "DoR run awaits the rubric"
has "$(sc | field r1-RETRO-5-intake "r['review']")" "rubric not graded" "review says why"
$SCORE grade $PJ --eval-root $DT_EVAL_ROOT --claude $DT_EVAL_CLAUDE >/dev/null; eq "$?" 0 "grade rc"
[ -f "$DT_EVAL_ROOT/runs/r1-RETRO-5-intake.a1/grade.json" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL grade.json not written"; }
eq "$(sc | field r1-RETRO-5-intake "r['status'],r['verdict'],r['tier'],r['ac_unmarked'],r['questions']['questions']")" "ok stop (DoR) None 0 3" "DoR run ok after grading (the 7 numbered gate sections are not counted as questions)"
# a grade that says not covered fails; a disagreement with the keyword check is listed
echo '{"covers_all": false, "missing": ["goal"], "superfluous": [], "notes": "x"}' > "$DT_EVAL_ROOT/runs/r1-RETRO-5-intake.a1/grade.json"
eq "$(sc | field r1-RETRO-5-intake "r['status']")" "fail" "rubric not covered -> fail"
has "$(sc | field r1-RETRO-5-intake "r['review']")" "disagree" "grader vs keywords disagreement is a review item"
scen y; FAKE_LANG=vi $RUN run $PJ $COMMON >/dev/null; $SCORE grade $PJ --eval-root $DT_EVAL_ROOT --claude $DT_EVAL_CLAUDE >/dev/null
eq "$(sc | field r1-RETRO-5-intake "r['status'],r['questions']['questions'],r['questions']['with_recommended'],r['questions']['with_options'],r['keyword_check']")" "ok 3 3 3 skipped" "Vietnamese question file: same shape check, keyword cross-check skipped"
scen z1; FAKE_MANYQ=1 $RUN run $PJ $COMMON >/dev/null; $SCORE grade $PJ --eval-root $DT_EVAL_ROOT --claude $DT_EVAL_CLAUDE >/dev/null
has "$(sc | field r1-RETRO-5-intake "r['fails']")" "6 questions in the draft" "more than 5 questions fails"
scen z2; FAKE_NOQFILE=1 $RUN run $PJ $COMMON >/dev/null; $SCORE grade $PJ --eval-root $DT_EVAL_ROOT --claude $DT_EVAL_CLAUDE >/dev/null
has "$(sc | field r1-RETRO-5-intake "r['review']")" "no tickets/RETRO-5-questions.md" "no questions file -> review, not a pass"
scen l; FAKE_TIER=A $RUN run $PJ --only WL-02 $COMMON >/dev/null
has "$(sc | field r1-WL-02-intake "r['fails']")" "HARD FAIL: tier A below B" "tier below the truth = hard fail"
scen m; FAKE_TIER=C $RUN run $PJ $COMMON >/dev/null
eq "$(sc | field r1-WL-02-intake "r['status'],r.get('above')")" "ok 1" "tier above the truth is counted, not a fail"
scen n; FAKE_VERDICT="stop (DoR)" $RUN run $PJ $COMMON >/dev/null
has "$(sc | field r1-WL-02-intake "r['fails']")" "verdict 'stop (DoR)', expected 'go'" "wrong verdict"
scen o; FAKE_NAMETIER=1 FAKE_AC=unmarked $RUN run $PJ $COMMON >/dev/null
has "$(sc | field r1-RETRO-5-intake "r['fails']")" "tier named on a stop (DoR) run" "tier on a DoR run"
has "$(sc | field r1-RETRO-5-intake "r['fails']")" "1 AC line(s) not marked PROPOSED" "unmarked AC"
scen p; FAKE_WORKTREE=/x/wt $RUN run $PJ $COMMON >/dev/null
has "$(sc | field r1-WL-02-intake "r['fails']")" "ticket file records a worktree" "worktree in the ticket file"
scen q; FAKE_LEAK=1 $RUN run $PJ $COMMON >/dev/null
has "$(sc | field r1-WL-02-intake "r['fails']")" "INVALID RUN" "cross-run read invalidates the run"
scen u; FAKE_WTREAD=1 $RUN run $PJ $COMMON >/dev/null
has "$(sc | field r1-WL-02-intake "r['fails']")" "INVALID RUN: line 2 .*reads a ticket worktree" "read under .claude/worktrees invalidates the run"
scen v; FAKE_BRANCH=1 $RUN run $PJ $COMMON >/dev/null
has "$(sc | field r1-WL-02-intake "r['fails']")" "references a finished ticket" "a fix/retro-N branch name invalidates the run"
scen w; FAKE_WTLIST=1 $RUN run $PJ $COMMON >/dev/null
eq "$(sc | field r1-WL-02-intake "r['status'],r['fails']")" "review []" "plain git worktree list is a review item, not invalid"
has "$(sc | field r1-WL-02-intake "r['review']")" "transcript-reads flagged" "listing shows under review"
scen r; $RUN run $PJ $COMMON >/dev/null
out=$($SCORE score $PJ --eval-root $DT_EVAL_ROOT --projects $S/nowhere); has "$out" "transcript not found" "missing transcript is a review item, not a pass"
scen s; $RUN run --only RETRO-8 --rounds 1 $COMMON >/dev/null
eq "$(sc | python3 -c "import json,sys;print(len(json.load(sys.stdin)['results']))")" 0 "pilot filter excludes RETRO-8"
out=$($SCORE score --rounds 1 --only RETRO-8 --json --eval-root $DT_EVAL_ROOT --projects $FAKE_PROJECTS)
eq "$(echo "$out" | python3 -c "import json,sys;d=json.load(sys.stdin);r=d['results'][0];print(r['status'],r['verdict'],sorted(r['part_tiers'].items()))")" "ok split [('Stop hook', 'C'), ('env-check skill', 'B'), ('verify-report skill', 'B')]" "split row: verdict + part tiers"
scen t; FAKE_STOPTIER=B $RUN run --only RETRO-8 --rounds 1 $COMMON >/dev/null
out=$($SCORE score --rounds 1 --only RETRO-8 --json --eval-root $DT_EVAL_ROOT --projects $FAKE_PROJECTS)
has "$out" "HARD FAIL: part 'Stop hook' tier B below C" "split part below the truth"
out=$($SCORE score --rounds 3 --only RETRO-8 --eval-root $DT_EVAL_ROOT --projects $FAKE_PROJECTS); has "$out" "INCOMPLETE" "missing rounds are reported as incomplete"; has "$out" "NOT PASSED" "incomplete is never a pass"

echo "# scope: v0.1 = 8 retro rows, WL = phase 6b"
scen x
out=$($RUN list --jobs r9-NOPE-intake $COMMON 2>&1); eq "$?" 2 "unknown job id -> rc 2"; has "$out" "unknown job id" "message"
out=$($RUN list $COMMON); has "$out" "45 job(s)" "default scope: 45 jobs"; hasnt "$out" "WL-" "default scope has no WL job"
out=$($RUN list --scope 6b $COMMON); has "$out" "18 job(s)" "6b scope: 6 WL rows x 3 rounds"; hasnt "$out" "RETRO" "6b scope has no retro job"
out=$($SCORE score --json --eval-root $DT_EVAL_ROOT --projects $FAKE_PROJECTS); eq "$(echo "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['summary']['rows_required'])")" 8 "verdict threshold is 8 rows in v0.1 scope"
out=$($SCORE score --scope all --json --eval-root $DT_EVAL_ROOT --projects $FAKE_PROJECTS); eq "$(echo "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['summary']['rows_required'])")" 14 "14 rows with --scope all"
out=$($SCORE score --json --eval-root $DT_EVAL_ROOT --projects $FAKE_PROJECTS); eq "$(echo "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['summary']['max_above'])")" 1 "over-tier threshold 1 of 8"
out=$($SCORE score --scope all --json --eval-root $DT_EVAL_ROOT --projects $FAKE_PROJECTS); eq "$(echo "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['summary']['max_above'])")" 2 "over-tier threshold 2 of 14"
out=$($SCORE score --eval-root $DT_EVAL_ROOT --projects $FAKE_PROJECTS); has "$out" "^scope: v0.1 (the 8 retro rows; the 6 WL rows are phase 6b" "the report states the scope"
echo "# the template state copy was never touched"
after=$(cd "$S/state" && find . -type f | sort | xargs shasum | shasum)
eq "$after" "$before" "template state unchanged"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
