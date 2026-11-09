#!/usr/bin/env python3
"""Runner of the phase-6 classification evals (plan section 12). One fresh `claude -p` session per job, serial.

  run-evals.py list    [--rounds 3] [--only ID,...] [--pilot]   what would run and what is already done
  run-evals.py prepare                                          write the input texts (verbatim from the notes) to <eval root>/inputs/
  run-evals.py run     [--rounds 3] [--only ID,...] [--pilot] [--batch N] [--timeout SEC]
  run-evals.py status  [--rounds 3] [--only ID,...] [--pilot]   done / failed / pending, wall time, cost, tokens

Jobs (63 for 3 rounds): per round and per row one `intake` job (`/deliver-ticket <ID> <ticket text>`; for the retro items the title
only), and for the 7 stop (DoR) rows a second `fixture` job (a fresh session with the title + the fixed goal / ACs). A session stops
at the first gate; `claude -p` ends its turn there. --pilot = the two jobs r1-WL-02-intake and r1-RETRO-5-intake.

Isolation: every attempt gets its own DELIVER_TICKET_HOME (<eval root>/runs/<job>.a<N>/home), seeded by COPYING config.md,
config.local.md, guard.json and project.md from the real state dir. The real state dir, RETRO-5 / RETRO-7 and the sessions map are
not touched; the runner compares a snapshot of the real project state dir and of the main checkout (git status, worktrees, branches,
HEAD) before and after every job, checks that no `sessions/<session id>` appeared in the real state root, and stops the queue when
any of these changed (another live ticket session writing to the real project state dir during a run also trips it). Nothing is ever deleted: attempts, partial output and homes stay (list them in
~/.local/share/deliver-ticket/build-cleanup-list.md and ask before removing).

Interruptions: a job whose session fails (non-zero exit, no `result` event, is_error, a non-success subtype, timeout, Ctrl-C, the
runner killed) is marked `failed`; the runner STOPS the queue (exit 3). The next invocation continues where it stopped: the failed job
is re-run from a fresh home (attempt N+1, never resumed); the failed attempt's partial output stays and is never scored. What
`claude -p` really does on a usage limit or an API error is UNVERIFIED; every one of the signs above counts as a failure, and a
result text that looks like a limit is labelled `limit_or_api`. --batch N runs at most N jobs in this invocation (default: all).

Exit codes: 0 all requested jobs done, 3 stopped on a failed session, 4 stopped on a safety change (repo or real state touched), 2 usage.
Environment: DT_EVAL_ROOT (default ~/.local/share/deliver-ticket-eval), DT_EVAL_CLAUDE (the claude binary, default `claude`).
"""
import argparse
import datetime
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evals_lib as L  # noqa: E402

HOME = os.path.expanduser("~")
EVAL_ROOT = os.environ.get("DT_EVAL_ROOT") or os.path.join(HOME, ".local/share/deliver-ticket-eval")
DEFAULT_REPO = os.path.join(HOME, "Desktop/Work/copilot-kit-training")
DEFAULT_NOTES = os.path.join(DEFAULT_REPO, "docs/training-v2")
DEFAULT_STATE = os.path.join(HOME, ".local/share/deliver-ticket/copilot-kit-training-cd02feca")
SEED_FILES = ["config.md", "config.local.md", "guard.json", "project.md"]
LIMIT_WORDS = ("usage limit", "rate limit", "rate_limit", "overloaded", "529", "429", "quota", "credit")


def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def git(repo, *args):
    r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else "ERR %d: %s" % (r.returncode, r.stderr.strip())


def repo_snapshot(repo):
    return {"status": git(repo, "status", "--porcelain=v1", "--untracked-files=all"),
            "worktrees": git(repo, "worktree", "list", "--porcelain"),
            "branches": git(repo, "branch", "--list", "--format=%(refname:short) %(objectname)"),
            "head": git(repo, "rev-parse", "HEAD").strip()}


def tree_snapshot(root):
    """sha1 over (relative path, size, mtime) of every file below root; (digest, file count)."""
    h, n = hashlib.sha1(), 0
    for d, dirs, files in os.walk(root):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(d, f)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            h.update(("%s\0%d\0%d\n" % (os.path.relpath(p, root), st.st_size, st.st_mtime_ns)).encode())
            n += 1
    return h.hexdigest(), n


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def attempts(job_id):
    """-> [(n, dir, meta|None)] oldest first."""
    runs = os.path.join(EVAL_ROOT, "runs")
    out = []
    if os.path.isdir(runs):
        for name in os.listdir(runs):
            if name.startswith(job_id + ".a") and name[len(job_id) + 2:].isdigit():
                d = os.path.join(runs, name)
                try:
                    meta = json.load(open(os.path.join(d, "meta.json")))
                except (OSError, ValueError):
                    meta = None
                out.append((int(name[len(job_id) + 2:]), d, meta))
    return sorted(out, key=lambda x: x[0])


def job_state(job_id):
    at = attempts(job_id)
    if any(m and m.get("status") == "done" for _, _, m in at):
        return "done"
    if not at:
        return "pending"
    return "failed"        # incl. 'running' left behind by a killed runner


def select_jobs(truth, a):
    only = set(a.only.split(",")) if a.only else None
    if a.pilot:
        return [j for j in L.jobs_for(truth, 1) if j["id"] in L.PILOT]
    return L.jobs_for(truth, a.rounds, only)


def job_text(truth, job, a):
    row = next(r for r in truth["rows"] if r["row"] == job["row"])
    return L.fixture_text(row, a.notes) if job["kind"] == "fixture" else L.intake_text(row, a.notes)


def cmd_prepare(truth, a):
    d = os.path.join(EVAL_ROOT, "inputs")
    os.makedirs(d, exist_ok=True)
    for r in truth["rows"]:
        for kind in ("intake", "fixture"):
            if kind == "fixture" and r["intake"] != "stop (DoR)":
                continue
            job = {"row": r["row"], "kind": kind}
            with open(os.path.join(d, "%s.%s.txt" % (r["id"], kind)), "w") as f:
                f.write(job_text(truth, job, a))
    print("inputs written to %s" % d)
    return 0


def cmd_list(truth, a):
    jobs = select_jobs(truth, a)
    for j in jobs:
        print("%-28s %s" % (j["id"], job_state(j["id"])))
    print("%d job(s); done %d, failed %d, pending %d" % (len(jobs), *[sum(1 for j in jobs if job_state(j["id"]) == s) for s in ("done", "failed", "pending")]))
    return 0


def seed_home(home, source_state):
    key = os.path.basename(source_state.rstrip("/"))
    dst = os.path.join(home, key)
    os.makedirs(dst)
    for n in SEED_FILES:
        src = os.path.join(source_state, n)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(dst, n))
    if not os.path.isfile(os.path.join(dst, "guard.json")):
        raise RuntimeError("no guard.json in %s (is the project initialised?)" % source_state)


def read_stream(path):
    init = result = None
    n = 0
    try:
        for line in open(path):
            try:
                d = json.loads(line)
            except ValueError:
                continue
            n += 1
            if d.get("type") == "system" and d.get("subtype") == "init":
                init = d
            elif d.get("type") == "result":
                result = d
    except OSError:
        pass
    return init, result, n


def run_job(truth, job, a):
    at = attempts(job["id"])
    n = (at[-1][0] + 1) if at else 1
    d = os.path.join(EVAL_ROOT, "runs", "%s.a%d" % (job["id"], n))
    home = os.path.join(d, "home")
    os.makedirs(d)
    text = job_text(truth, job, a).rstrip("\n")
    prompt = "/deliver-ticket %s %s" % (job["ticket"], text)
    with open(os.path.join(d, "prompt.txt"), "w") as f:
        f.write(prompt + "\n")
    meta = {"job": job["id"], "attempt": n, "round": job["round"], "ticket": job["ticket"], "kind": job["kind"], "row": job["row"],
            "status": "running", "started": now(), "home": home, "repo": a.repo}
    write_json(os.path.join(d, "meta.json"), meta)
    seed_home(home, a.source_state)
    env = dict(os.environ, DELIVER_TICKET_HOME=home, CLAUDE_CODE_DISABLE_AUTO_MEMORY="1")
    env.pop("CLAUDECODE", None)
    cmd = [a.claude, "-p", "--permission-mode", "auto", "--output-format", "stream-json", "--verbose", prompt]
    before, real_before = repo_snapshot(a.repo), tree_snapshot(a.source_state)
    stream = os.path.join(d, "stream.jsonl")
    t0 = time.time()
    reason = None
    with open(stream, "w") as so, open(os.path.join(d, "stderr.txt"), "w") as se:
        p = subprocess.Popen(cmd, cwd=a.repo, env=env, stdout=so, stderr=se, stdin=subprocess.DEVNULL, start_new_session=True)
        try:
            p.wait(timeout=a.timeout)
        except subprocess.TimeoutExpired:
            reason = "timeout after %ds" % a.timeout
            kill(p)
        except BaseException:
            kill(p)
            meta.update(status="failed", reason="interrupted", ended=now(), wall_s=round(time.time() - t0, 1))
            write_json(os.path.join(d, "meta.json"), meta)
            raise
    meta["wall_s"] = round(time.time() - t0, 1)
    meta["exit_code"] = p.returncode
    init, result, events = read_stream(stream)
    meta["events"] = events
    meta["session_id"] = (result or {}).get("session_id") or (init or {}).get("session_id")
    if result:
        meta["result"] = {k: result.get(k) for k in ("subtype", "is_error", "duration_ms", "num_turns", "total_cost_usd", "usage") if k in result}
        meta["final_message"] = result.get("result") if isinstance(result.get("result"), str) else None
    if reason is None:
        if p.returncode != 0:
            reason = "exit code %s" % p.returncode
        elif result is None:
            reason = "no result event in the stream"
        elif result.get("is_error") or result.get("subtype") not in (None, "success"):
            reason = "result is_error=%s subtype=%s: %s" % (result.get("is_error"), result.get("subtype"), str(result.get("result"))[:200])
    if reason and any(w in (reason + " " + str((result or {}).get("result"))).lower() for w in LIMIT_WORDS):
        reason = "limit_or_api: " + reason
    safety = []
    after = repo_snapshot(a.repo)
    changed = [k for k in before if before[k] != after[k]]
    if changed:
        safety.append("main checkout changed (%s)" % ", ".join(changed))
    if tree_snapshot(a.source_state) != real_before:
        safety.append("real project state dir changed")
    if meta["session_id"] and os.path.exists(os.path.join(a.real_home, "sessions", meta["session_id"])):
        safety.append("session was bound in the real state dir")
    meta.update(status="failed" if reason else "done", ended=now(), safety=safety)
    if reason:
        meta["reason"] = reason
    write_json(os.path.join(d, "meta.json"), meta)
    return meta


def kill(p):
    try:
        os.killpg(p.pid, signal.SIGTERM)
        p.wait(timeout=10)
    except Exception:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except Exception:
            pass
        p.wait()


def cmd_run(truth, a):
    cmd_prepare(truth, a)
    jobs = select_jobs(truth, a)
    pending = [j for j in jobs if job_state(j["id"]) != "done"]
    todo = pending[:a.batch] if a.batch else pending
    print("%d job(s) selected, %d not done, running %d (serial)" % (len(jobs), len(pending), len(todo)))
    for i, j in enumerate(todo, 1):
        print("[%d/%d] %s ..." % (i, len(todo), j["id"]), flush=True)
        m = run_job(truth, j, a)
        print("      %s in %.0fs%s" % (m["status"], m["wall_s"], " - " + m["reason"] if m.get("reason") else ""), flush=True)
        if m["status"] == "failed":
            print("STOPPED: %s failed (attempt %d kept, not scored). Run the same command again to continue; this job is re-run from a fresh home." % (j["id"], m["attempt"]))
            return 3
        if m["safety"]:
            print("STOPPED: %s: %s. Look before running anything else." % (j["id"], "; ".join(m["safety"])))
            return 4
    left = sum(1 for j in jobs if job_state(j["id"]) != "done")
    print("done; %d of the %d selected job(s) still not done" % (left, len(jobs)))
    return 0


def cmd_status(truth, a):
    jobs = select_jobs(truth, a)
    st = {"done": 0, "failed": 0, "pending": 0}
    wall = cost = 0.0
    tok = {"input_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0, "output_tokens": 0}
    per_kind = {}
    for j in jobs:
        s = job_state(j["id"])
        st[s] += 1
        for n, d, m in attempts(j["id"]):
            if not m:
                continue
            if m.get("safety"):
                print("SAFETY %s a%d: %s" % (j["id"], n, "; ".join(m["safety"])))
            if s == "failed" and m.get("status") == "failed":
                print("FAILED %s a%d: %s" % (j["id"], n, m.get("reason")))
            if m.get("status") == "done":
                wall += m.get("wall_s", 0)
                r = m.get("result") or {}
                cost += r.get("total_cost_usd") or 0
                for k in tok:
                    tok[k] += (r.get("usage") or {}).get(k, 0) or 0
                per_kind.setdefault(j["kind"], []).append(m.get("wall_s", 0))
    print("jobs: done %d, failed %d, pending %d (of %d)" % (st["done"], st["failed"], st["pending"], len(jobs)))
    if st["done"]:
        print("wall time of done attempts: %.0fs total, %.0fs per job" % (wall, wall / st["done"]))
        for k, v in sorted(per_kind.items()):
            print("  %-8s %d job(s), mean %.0fs, max %.0fs" % (k, len(v), sum(v) / len(v), max(v)))
        print("tokens (sum of the result events): " + ", ".join("%s %d" % (k, v) for k, v in tok.items()))
        print("cost reported by claude: $%.2f (0 = not reported)" % cost)
    return 0


def main():
    ap = argparse.ArgumentParser(prog="run-evals.py", description=__doc__.split("\n\n")[0])
    ap.add_argument("cmd", choices=["list", "prepare", "run", "status"])
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--only")
    ap.add_argument("--pilot", action="store_true")
    ap.add_argument("--batch", type=int, default=0, help="max jobs in this invocation (default: all)")
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--truth", default=L.TRUTH)
    ap.add_argument("--notes", default=DEFAULT_NOTES, help="directory with capstone/tickets.md and day-15.md")
    ap.add_argument("--repo", default=DEFAULT_REPO, help="main checkout the sessions run in")
    ap.add_argument("--source-state", default=DEFAULT_STATE, help="real state dir that is copied into every run home")
    ap.add_argument("--real-home", help="real DELIVER_TICKET_HOME, checked for a bound eval session (default: parent of --source-state)")
    ap.add_argument("--claude", default=os.environ.get("DT_EVAL_CLAUDE", "claude"))
    a = ap.parse_args()
    a.real_home = a.real_home or os.path.dirname(a.source_state.rstrip("/"))
    if os.path.realpath(EVAL_ROOT).startswith(os.path.realpath(a.real_home) + os.sep) or os.path.realpath(a.real_home).startswith(os.path.realpath(EVAL_ROOT) + os.sep):
        print("the eval root and the real state dir must not contain each other", file=sys.stderr)
        return 2
    try:
        truth = L.load_truth(a.truth)
    except (OSError, ValueError) as e:
        print("cannot read %s: %s" % (a.truth, e), file=sys.stderr)
        return 2
    try:
        return {"list": cmd_list, "prepare": cmd_prepare, "run": cmd_run, "status": cmd_status}[a.cmd](truth, a)
    except (RuntimeError, ValueError, OSError) as e:
        print("error: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
