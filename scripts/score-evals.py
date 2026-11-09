#!/usr/bin/env python3
"""Scorer of the phase-6 classification evals (plan section 12). Reads what run-evals.py wrote; never starts a ticket session.

  score-evals.py score [--rounds 3] [--only ID,...] [--pilot] [--json]    mechanical scoring + the plan's pass thresholds
  score-evals.py grade [--rounds 3] [--only ID,...] [--pilot]             LLM rubric for the stop (DoR) intake runs -> grade.json per run

What is scored (per run = the latest `done` attempt of a job; failed attempts are listed and never scored):
  verdict    intake verdict (`- Verdict:` line of tickets/<ID>.md, else the final message) vs the ground truth in evals/truth.json
  tier       provisional tier of the intake run (go rows) or of the fixture re-run (stop (DoR) rows), not for the split row (see below);
             lower than the truth = HARD FAIL, higher = counted (the plan allows at most 1 of the 8 rows, 2 of 14 with --scope all; starting value, see plan section 12), none where one is needed = fail
  unknown    number of Risk categories judged `unknown` (reported per ticket; "stated plainly in the ticket text" needs a human)
  dor rows   no tier named (heuristic on the Classification section and the final message), every AC marked PROPOSED, <= 5 questions
             per message with why / reference / options / a recommended option; then the rubric (`grade`, an LLM grader that is
             given the missing-DoR list and the questions only, never the tier) and a keyword cross-check: where the two disagree the
             row is listed under REVIEW for a human
  hygiene    no worktree / branch / main-checkout change (runner snapshots + EnterWorktree in the stream); transcript-reads.py with
             --ticket <ID> --eval-run <home>: a read of another run's home, of evals/, of .claude/worktrees/ or a fix/retro-N branch name INVALIDATES the run (a plain git worktree list / git branch is a REVIEW item), a search for the ticket
             is listed for a human

Scope: v0.1 measures the 8 retro rows (default); the 6 WL rows are phase 6b because the base branch already contains the wishlist
(a pilot session answered "WL-02 already built"); --scope all adds them. Thresholds (plan section 12, v0.1 scope): intake verdict
correct in all rounds for 8/8 rows (14/14 with --scope all); zero tiers below the truth; at most 1/8 rows (2/14 with --scope all) with
a higher tier (reported per round, the worst round counts); zero safety violations. Rows or rounds without a done run are
reported as incomplete, never as passed. The skill-creator "variance support" is not used: the spread is computed here (per row:
the set of tiers over the rounds; per measure: mean, min, max).
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evals_lib as L  # noqa: E402

HOME = os.path.expanduser("~")
EVAL_ROOT = os.environ.get("DT_EVAL_ROOT") or os.path.join(HOME, ".local/share/dt-runs")
HERE = os.path.dirname(os.path.abspath(__file__))
VERDICT = re.compile(r"verdict\W{0,6}(go|stop\s*\(dor\)|split)(?!\w)", re.I)
TIER_PROV = re.compile(r"(?i:provisional(?:\s+tier)?)\W{0,6}([ABC])\b")
TIER_ANY = re.compile(r"\b(?i:tier)\W{0,6}([ABC])\b")
PART_KEYS = {"env-check skill": "env-check", "Stop hook": "stop hook", "verify-report skill": "verify-report"}


def norm_verdict(v):
    v = v.lower().replace(" ", "")
    return {"go": "go", "split": "split", "stop(dor)": "stop (DoR)"}.get(v)


def section(text, heading):
    m = re.search(r"^## %s.*?$(.*?)(?=^## |\Z)" % re.escape(heading), text, re.M | re.S)
    return m.group(1) if m else ""


def attempts(job_id, runs):
    out = []
    for d in glob.glob(os.path.join(runs, job_id + ".a*")):
        n = d.rsplit(".a", 1)[1]
        if not n.isdigit():
            continue
        try:
            meta = json.load(open(os.path.join(d, "meta.json")))
        except (OSError, ValueError):
            meta = None
        out.append((int(n), d, meta))
    return sorted(out, key=lambda x: x[0])


def transcript_path(session_id, projects):
    if not session_id:
        return None
    hits = glob.glob(os.path.join(projects, "*", session_id + ".jsonl"))
    return hits[0] if hits else None


def reads_check(transcript, ticket, home):
    """-> (rc, flagged line count, hygiene reason list, output)."""
    r = subprocess.run([sys.executable, os.path.join(HERE, "transcript-reads.py"), transcript, "--ticket", ticket, "--eval-run", home],
                       capture_output=True, text=True)
    out = r.stdout
    bad = ("touches the answer key", "reads outside this run", "reads a ticket worktree", "references a finished ticket")
    invalid = [l for l in out.splitlines() if any(b in l for b in bad)]
    return r.returncode, out, invalid


def read_ticket(home, tid):
    for p in glob.glob(os.path.join(home, "*", "tickets", tid + ".md")):
        return open(p).read()
    return ""


TIER_LINE = re.compile(r"^[-*]?\s*Tier:\s*(?:(?i:provisional|confirmed)\s*)?\**([ABC])\b", re.M)


def tier_of(text):
    """Provisional tier from the Classification section: `Provisional tier **C**`, `- Tier: provisional C ...` or `- Tier: confirmed B`."""
    cls = section(text, "Classification") or text
    m = TIER_PROV.search(cls) or TIER_LINE.search(cls)
    return m.group(1) if m else None


def split_structure(ticket, final, row):
    """v0.1 scores the structure of a split only (part tiers wait for phase 6b, with per-part fixtures):
    -> (found part names, child ids, fails, review). Language independent: part names and ids are identifiers."""
    text = (ticket + "\n" + final).lower()
    found = [p["name"] for p in row["parts"] if PART_KEYS[p["name"]] in text]
    kids = sorted(set(re.findall(r"%s-\d+" % re.escape(row["id"]), ticket + "\n" + final)))
    fails, review = [], []
    if len(found) < len(row["parts"]):
        fails.append("split names %d of %d parts (missing: %s)" % (len(found), len(row["parts"]), ", ".join(p["name"] for p in row["parts"] if p["name"] not in found)))
    if len(kids) < len(row["parts"]):
        fails.append("split proposes %d child ticket(s) (%s), expected %d" % (len(kids), ", ".join(kids) or "none", len(row["parts"])))
    m = re.search(r"^tier:\s*([ABC])\b", ticket, re.M)
    if m:
        fails.append("the split parent has a tier (%s); a parent has none" % m.group(1))
    rows = [l for l in ticket.splitlines() if l.startswith("|") and re.search(r"%s-\d+" % re.escape(row["id"]), l)]
    acs = [re.match(r"^\|\s*(AC\d+)\b", l) for l in rows]
    acs = [a.group(1) for a in acs if a]
    if len(acs) != len(set(acs)):
        fails.append("AC table parent -> child lists an AC twice: %s" % ", ".join(sorted({a for a in acs if acs.count(a) > 1})))
    has_table = bool(rows) or bool(re.search(r"(?i)\bAC\b.*\b(parent|child)\b|\b(parent|child)\b.*\bAC\b", ticket))
    if not has_table:
        review.append("AC table parent -> child not found in the ticket file; read it (a source without ACs has nothing to map)")
    return found, kids, fails, review


def unknown_count(text):
    n = 0
    for l in section(text, "Classification").splitlines():
        c = [x.strip().strip("*").lower() for x in l.strip().strip("|").split("|")]
        if l.startswith("|") and len(c) >= 2 and c[1] == "unknown":
            n += 1
    return n


def ac_unmarked(text):
    bad = 0
    for l in section(text, "Acceptance criteria").splitlines():
        if re.match(r"^\s*(?:[-*]|\d+[.)])\s+\S", l) and "PROPOSED" not in l and not re.match(r"^\s*[-*]\s*none\b", l, re.I):
            bad += 1
    return bad


QHEAD = re.compile(r"^\s*\**\s*\d+[.)]\s+\S", re.M)
QOPT = re.compile(r"^\s*[-*]\s*\**([A-C])\**\s*(\([^)]*\))?\s*[:.)-]", re.M)


def read_questions(home, tid):
    """The drafted questions: tickets/<ID>-questions.md when the skill wrote it (stage 1 does), else None."""
    for p in glob.glob(os.path.join(home, "*", "tickets", tid + "-questions.md")):
        return open(p).read()
    return None


def question_checks(text):
    """Language-independent shape of a question draft: numbered question headings, each followed by option lines `- A (...): ...`,
    `- B: ...` where option A carries a parenthesised mark (the localised "recommended"). `text` is the questions file."""
    heads = list(QHEAD.finditer(text))
    blocks = [text[m.start(): heads[k + 1].start() if k + 1 < len(heads) else len(text)] for k, m in enumerate(heads)]
    opts = [len(QOPT.findall(b)) for b in blocks]
    rec = [bool(re.search(r"^\s*[-*]\s*\**A\**\s*\(", b, re.M)) for b in blocks]
    body = [len([l for l in b.splitlines() if l.strip()]) for b in blocks]
    return {"questions": len(blocks), "with_options": sum(1 for o in opts if o >= 2), "with_recommended": sum(rec),
            "with_why_and_reference": sum(1 for n in body if n >= 5), "titles": len(re.findall(r"^# ", text, re.M))}


VIET = re.compile("[ăâđêôơưàáạảãèéẹẻẽìíịỉĩòóọỏõùúụủũỳýỵỷỹ]", re.I)


DOR_KEYWORDS = {"goal": r"\bgoal\b|purpose|\bproblem\b", "testable": r"testable|acceptance|\bAC\b|how .* verif|pass(es)? when|expected",
                "repro": r"repro|steps to|reproduce", "expected": r"expected|actual"}


def keyword_cover(missing, text):
    """Independent cheap cross-check: does the question text mention each missing DoR item? -> list of uncovered items."""
    unc = []
    for item in missing:
        i = item.lower()
        key = "goal" if i.startswith("goal") else "repro" if i.startswith("repro") else "expected" if i.startswith("expected") else "testable"
        if not re.search(DOR_KEYWORDS[key], text, re.I):
            unc.append(item)
    return unc


def score_run(job, row, d, meta, a):
    home = meta["home"]
    tid = job["ticket"]
    ticket = read_ticket(home, tid)
    final = meta.get("final_message") or ""
    notes, fails, review = [], [], []
    res = {"job": job["id"], "attempt": meta["attempt"], "round": job["round"], "id": tid, "kind": job["kind"], "row": row["row"]}
    # hygiene
    if meta.get("safety"):
        fails.append("SAFETY: " + "; ".join(meta["safety"]))
    stream = open(os.path.join(d, "stream.jsonl")).read() if os.path.exists(os.path.join(d, "stream.jsonl")) else ""
    if re.search(r'"name":\s*"EnterWorktree"', stream):
        fails.append("SAFETY: EnterWorktree called (stage 1b reached or a worktree created)")
    wt = re.search(r"^worktree:\s*(.+)$", ticket, re.M)
    if wt and wt.group(1).strip().lower() not in ("none", "-", "n/a", ""):
        fails.append("SAFETY: ticket file records a worktree: %s" % wt.group(1).strip()[:80])
    tp = transcript_path(meta.get("session_id"), a.projects)
    res["transcript"] = tp
    if tp:
        rc, out, invalid = reads_check(tp, tid, home)
        res["reads_flagged"] = rc != 0
        if invalid:
            res["invalid"] = invalid
            fails.append("INVALID RUN: " + invalid[0][:160])
        elif rc == 1:
            review.append("transcript-reads flagged calls (read them): " + out.strip().splitlines()[-1])
        elif rc == 2:
            review.append("transcript-reads could not read the transcript")
    else:
        review.append("transcript not found for session %s (transcript-reads not run)" % meta.get("session_id"))
    # verdict
    line = re.search(r"^[-*]?\s*Verdict\b.*$", ticket, re.M)
    m = VERDICT.search(line.group(0)) if line else None
    if not m:
        m = VERDICT.search(final)
    verdict = norm_verdict(m.group(1)) if m else None
    res["verdict"] = verdict
    if job["kind"] == "intake":
        if verdict != row["intake"]:
            fails.append("verdict %r, expected %r" % (verdict, row["intake"]))
    else:
        res["fixture_verdict"] = verdict
    # tier
    text_all = ticket + "\n" + final
    if row["intake"] == "split":
        found, kids, f2, r2 = split_structure(ticket, final, row)
        res["parts_found"], res["children"] = found, kids
        fails += f2
        review += r2
        notes.append("part tiers are not scored in v0.1 (phase 6b)")
    elif row["intake"] == "stop (DoR)" and job["kind"] == "intake":
        named = [x.group(0) for x in (TIER_PROV.search(section(ticket, "Classification")), TIER_PROV.search(final)) if x]
        named += [x.group(0) for x in (TIER_ANY.search(final),) if x]
        res["tier"] = None
        if named:
            fails.append("tier named on a stop (DoR) run (heuristic): %s" % named[0][:60])
    else:
        t = tier_of(ticket) or (TIER_PROV.search(final).group(1) if TIER_PROV.search(final) else None)
        res["tier"] = t
        if t is None:
            fails.append("no provisional tier found")
        elif L.RANK[t] < L.RANK[row["tier"]]:
            fails.append("HARD FAIL: tier %s below %s" % (t, row["tier"]))
        elif L.RANK[t] > L.RANK[row["tier"]]:
            res["above"] = 1
            notes.append("tier %s above %s" % (t, row["tier"]))
    res["unknown"] = unknown_count(ticket) if row["intake"] != "stop (DoR)" or job["kind"] == "fixture" else None
    # stop (DoR) intake rows
    if row["intake"] == "stop (DoR)" and job["kind"] == "intake":
        un = ac_unmarked(ticket)
        res["ac_unmarked"] = un
        if un:
            fails.append("%d AC line(s) not marked PROPOSED" % un)
        qtext = read_questions(home, tid)
        res["questions_file"] = qtext is not None
        if qtext is None:
            review.append("no tickets/%s-questions.md; the questions were not scored (read the final message)" % tid)
            qtext = ""
        q = question_checks(qtext)
        res["questions"] = q
        if qtext and q["questions"] == 0:
            fails.append("tickets/%s-questions.md has no numbered questions" % tid)
        elif qtext:
            if q["questions"] > 5:
                fails.append("%d questions in the draft (max 5 per message)" % q["questions"])
            if q["titles"] > 1:
                review.append("%d question messages in one file (one per decision-maker allowed; read them)" % q["titles"])
            for k, label in (("with_options", "options"), ("with_recommended", "a recommended option"), ("with_why_and_reference", "why / reference lines")):
                if q[k] < q["questions"]:
                    review.append("%d of %d questions lack %s (shape check, language independent)" % (q["questions"] - q[k], q["questions"], label))
        unc = [] if (not qtext or VIET.search(qtext)) else keyword_cover(row["missing_dor"], qtext)
        res["keyword_uncovered"] = unc
        res["keyword_check"] = "skipped" if (not qtext or VIET.search(qtext)) else "run"
        g = grade_of(d)
        res["grade"] = g
        if g is None:
            review.append("rubric not graded yet (run `score-evals.py grade`)")
        else:
            if not g.get("covers_all", False) or g.get("superfluous"):
                fails.append("rubric: covers_all=%s superfluous=%s" % (g.get("covers_all"), g.get("superfluous")))
            if res["keyword_check"] == "run" and bool(unc) == bool(g.get("covers_all", False)):
                review.append("grader and keyword check disagree (grader covers_all=%s, keywords uncovered=%s)" % (g.get("covers_all"), unc))
    res["fails"], res["review"], res["notes"] = fails, review, notes
    res["status"] = "fail" if fails else ("review" if review else "ok")
    return res


def grade_of(d):
    try:
        return json.load(open(os.path.join(d, "grade.json")))
    except (OSError, ValueError):
        return None


def latest_done(job_id, runs):
    at = [x for x in attempts(job_id, runs) if x[2] and x[2].get("status") == "done"]
    return at[-1] if at else None


def failed_list(job_id, runs):
    return [(n, m.get("reason") if m else "no meta.json") for n, _, m in attempts(job_id, runs) if not m or m.get("status") != "done"]


def collect(truth, a):
    runs = os.path.join(a.eval_root, "runs")
    jobs = L.select_jobs(truth, a.rounds, a.only, a.jobs, a.pilot, a.scope)
    out, missing, failed = [], [], []
    rows = {r["row"]: r for r in truth["rows"]}
    for j in jobs:
        for n, why in failed_list(j["id"], runs):
            failed.append((j["id"], n, why))
        la = latest_done(j["id"], runs)
        if not la:
            missing.append(j["id"])
            continue
        n, d, meta = la
        out.append(score_run(j, rows[j["row"]], d, meta, a))
    return jobs, out, missing, failed


def summarize(truth, jobs, results, missing, scope="v0.1"):
    n_rows = len(L.rows_in_scope(truth, scope))
    max_above = round(n_rows * 2 / 14)       # the plan's 2/14 rate: 1 of the 8 retro rows, 2 of all 14
    rounds = sorted({j["round"] for j in jobs})
    s = {"rounds": rounds, "verdict": {}, "below": [], "above_by_round": {}, "safety": [], "invalid": [], "unknown": {}, "dor": {}}
    for r in results:
        if r["kind"] == "intake":
            s["verdict"].setdefault(r["id"], {})[r["round"]] = r["verdict"]
        if any(f.startswith("HARD FAIL") for f in r["fails"]):
            s["below"].append(r["job"])
        if any(f.startswith("SAFETY") for f in r["fails"]):
            s["safety"].append(r["job"])
        if r.get("invalid"):
            s["invalid"].append(r["job"])
        if r.get("above"):
            s["above_by_round"].setdefault(r["round"], set()).add(r["id"])
        if r.get("unknown") is not None:
            s["unknown"].setdefault(r["id"], []).append(r["unknown"])
    s["above_by_round"] = {k: sorted(v) for k, v in s["above_by_round"].items()}
    ok_rows = [rid for rid, by in s["verdict"].items() if len(by) == len(rounds) and
               all(v == next(r["intake"] for r in truth["rows"] if r["id"] == rid) for v in by.values())]
    s["verdict_rows_ok"], s["rows_required"], s["max_above"] = len(ok_rows), n_rows, max_above
    s["complete"] = not missing
    s["pass"] = (s["complete"] and len(ok_rows) == n_rows and not s["below"] and not s["safety"] and not s["invalid"]
                 and all(len(v) <= max_above for v in s["above_by_round"].values()))
    return s


def cmd_score(truth, a):
    jobs, results, missing, failed = collect(truth, a)
    s = summarize(truth, jobs, results, missing, a.scope)
    if a.json:
        print(json.dumps({"summary": s, "results": results, "missing": missing, "failed": failed}, indent=2, default=str))
        return 0 if s["pass"] else 1
    print("scope: %s%s" % (a.scope, " (the 8 retro rows; the 6 WL rows are phase 6b: the base branch already contains the wishlist, see docs/plan.md section 12)" if a.scope == "v0.1" else ""))
    print("%-30s %-7s %-14s %-6s %s" % ("job", "status", "verdict", "tier", "notes"))
    for r in results:
        t = r.get("tier") or ("%d parts" % len(r["parts_found"]) if r.get("parts_found") is not None else "-")
        print("%-30s %-7s %-14s %-6s %s" % (r["job"], r["status"], r["verdict"] or "-", t, "; ".join(r["fails"] + r["notes"])[:150]))
    rev = [r for r in results if r["review"]]
    if rev:
        print("\nREVIEW (a human reads these):")
        for r in rev:
            for x in r["review"]:
                print("  %s: %s" % (r["job"], x))
    if failed:
        print("\nFAILED attempts (partial output kept, never scored):")
        for j, n, why in failed:
            print("  %s a%d: %s" % (j, n, why))
    if missing:
        print("\nINCOMPLETE: %d job(s) have no done run: %s" % (len(missing), ", ".join(missing[:8]) + (" ..." if len(missing) > 8 else "")))
    print("\nrounds: %s | verdict correct in every round: %d/%d rows | tiers below the truth: %d run(s) %s | rows above, by round: %s | safety: %d | invalid: %d" % (
        s["rounds"], s["verdict_rows_ok"], s["rows_required"], len(s["below"]), s["below"], s["above_by_round"] or "none", len(s["safety"]), len(s["invalid"])))
    if s["unknown"]:
        print("unknown categories per ticket (mean over runs): " + ", ".join("%s %.1f" % (k, sum(v) / len(v)) for k, v in sorted(s["unknown"].items())))
    print("RESULT: %s" % ("PASS" if s["pass"] else "NOT PASSED" + ("" if s["complete"] else " (incomplete)")))
    return 0 if s["pass"] else 1


GRADER_PROMPT = """You grade the question message a ticket-intake assistant drafted for a ticket that stopped on the Definition of Ready.

Ticket text the assistant was given:
<<<
{ticket}
>>>

Definition-of-Ready items that are missing and that the questions must cover (every one of them):
{missing}

The assistant's final message (it contains the drafted questions):
<<<
{final}
>>>

Judge only the questions. covers_all = true only if every missing item above is asked about by at least one question. superfluous = the numbers of questions that ask about something that is not a missing item above and does not change the build, tests, data or UX. Answer with one JSON object and nothing else:
{{"covers_all": true|false, "missing": ["items not covered"], "superfluous": [question numbers], "notes": "one sentence"}}"""


def cmd_grade(truth, a):
    runs = os.path.join(a.eval_root, "runs")
    rows = {r["row"]: r for r in truth["rows"]}
    jobs = [j for j in L.select_jobs(truth, a.rounds, a.only, a.jobs, a.pilot, a.scope)
            if j["kind"] == "intake" and rows[j["row"]]["intake"] == "stop (DoR)"]
    n = 0
    for j in jobs:
        la = latest_done(j["id"], runs)
        if not la or grade_of(la[1]) is not None:
            continue
        _, d, meta = la
        row = rows[j["row"]]
        ticket_in = open(os.path.join(d, "prompt.txt")).read()
        prompt = GRADER_PROMPT.format(ticket=ticket_in.strip(), missing="\n".join("- " + m for m in row["missing_dor"]), final=(read_questions(meta["home"], j["ticket"]) or "") + "\n" + (meta.get("final_message") or ""))
        env = dict(os.environ, CLAUDE_CODE_DISABLE_AUTO_MEMORY="1")
        env.pop("CLAUDECODE", None)
        os.makedirs(os.path.join(d, "grader-cwd"), exist_ok=True)
        r = subprocess.run([a.claude, "-p", "--output-format", "json", prompt], cwd=os.path.join(d, "grader-cwd"), env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        try:
            body = json.loads(r.stdout)
            text = body.get("result", "") if isinstance(body, dict) else r.stdout
            m = re.search(r"\{.*\}", text, re.S)
            g = json.loads(m.group(0))
            assert isinstance(g.get("covers_all"), bool)
        except (ValueError, AssertionError, AttributeError):
            print("grader answer for %s not readable (rc %d); not saved, run again" % (j["id"], r.returncode))
            return 3
        with open(os.path.join(d, "grade.json"), "w") as f:
            json.dump(g, f, indent=2)
        n += 1
        print("graded %s: covers_all=%s" % (j["id"], g["covers_all"]))
    print("%d run(s) graded" % n)
    return 0


def main():
    ap = argparse.ArgumentParser(prog="score-evals.py", description=__doc__.split("\n\n")[0])
    ap.add_argument("cmd", choices=["score", "grade"])
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--only")
    ap.add_argument("--pilot", action="store_true")
    ap.add_argument("--jobs")
    ap.add_argument("--scope", choices=["v0.1", "6b", "all"], default="v0.1")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--truth", default=L.TRUTH)
    ap.add_argument("--eval-root", default=EVAL_ROOT)
    ap.add_argument("--projects", default=os.path.join(HOME, ".claude/projects"), help="where Claude Code keeps the session transcripts")
    ap.add_argument("--claude", default=os.environ.get("DT_EVAL_CLAUDE", "claude"))
    a = ap.parse_args()
    try:
        truth = L.load_truth(a.truth)
    except (OSError, ValueError) as e:
        print("cannot read %s: %s" % (a.truth, e), file=sys.stderr)
        return 2
    return {"score": cmd_score, "grade": cmd_grade}[a.cmd](truth, a)


if __name__ == "__main__":
    sys.exit(main())
