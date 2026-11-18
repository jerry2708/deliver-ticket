#!/usr/bin/env python3
"""scripts/lock-trace.sh <ID> --repo <main checkout> --session <current session id> [--projects DIR]   (read-only; runs inside the sandbox)

Stage 8 trace of the plan lock (plan.md, milestone 1c, section 3b): what the lock does NOT stop, read back from the session transcripts. A trace, not proof:
the transcripts live under ~/.claude/projects, which Claude can write (memory), so a missing line proves nothing.

Sessions: every `session=` of the ticket's lines in <state>/delivery.log, plus --session. Each one's transcript is <projects>/*/<sid>.jsonl (the main one) and
<projects>/*/<sid>/subagents/*.jsonl; a session with no main transcript is listed as missing, never skipped. Only `user` / `assistant` entries are read.
Listed (each counts):
  missing     a session id with no transcript file
  unparsed    a Bash call the hooks cannot see into (an interpreter reading its program from stdin: `python3 - <<EOF`, `bash < x`; python3 -c, node -e, perl / ruby -e, an interpreter or ./ running a script file that is not the skill's,
              make, npm / pnpm / yarn / bun run|exec|dlx, npx, find with xargs or -exec, a nested claude), made BEFORE the current marker was written
              (no marker: all of them). The ones after it are printed as `after-marker` and not counted (building runs make / npm run all the time).
  approvals   any tool call whose input names approvals/
  marker      no marker, an untrusted marker, or its hash differs from the current plan section
  approve     an approve-plan.sh <ID> --sha X call whose X differs from the last `plan hash` line in Claude's text before it, that has no such line, with no user
              turn between that line and the call ("approved without a user turn"), that ran in a subagent, or whose sha256 has no `plan-approve` line in
              delivery.log; and a `plan-approve` line in delivery.log that no scanned approve-plan.sh call explains
  session     a session id (--session or from delivery.log) that is not a plain id (no "/", no ".."): not looked up
  projects    --projects other than ~/.claude/projects (realpath): only the tests pass it; stage 8 never does
  start       a session with no <state root>/starts/<sid> record, or whose transcript has a cwd that is neither under the record nor under <repo>/.claude/worktrees
A user turn: a `user` entry that is not isMeta, not a compact summary, not a tool result, not "[Request interrupted...".
Writes nothing. Exit 0 = nothing listed, 1 = at least one line listed, 2 = bad input. Standard library only.
"""
import argparse
import calendar
import glob
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
SK = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import plan_lock  # noqa: E402
import ticket_ctl  # noqa: E402

SID_RE = re.compile(r"(?!.*\.\.)[A-Za-z0-9][A-Za-z0-9._-]{0,127}")     # a plain session id: no "/", no "..", not starting with "." or "-"
DEFAULT_PROJECTS = os.path.join(os.path.expanduser("~"), ".claude", "projects")
HASH_SHOWN = re.compile(r"plan hash ([0-9a-f]{12})\b")
# start of a simple command: line start, ; & | ( ` $( or a newline, then optional VAR=x assignments
CMD = r"(?:^|[;&|(\n`]|\$\()\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*"
END = r"(?=\s|$|[;&|)`])"                  # the end of a command name (`make` but not `make-x`, `claude` but not `claude-x`)
UNPARSED = [
    ("interpreter stdin", re.compile(CMD + r"(?:python[0-9.]*|node|perl|ruby|bash|sh|zsh)\s+(?:-\S+\s+)*(?:-(?=\s|$)|<<|<\s*\S)")),
    ("python -c", re.compile(CMD + r"python[0-9.]*\s+(?:-\S+\s+)*-c\b")),
    ("node -e", re.compile(CMD + r"node\s+(?:-\S+\s+)*(?:-e|--eval|-p|--print)\b")),
    ("perl/ruby -e", re.compile(CMD + r"(?:perl|ruby)\s+(?:-\S+\s+)*-e\b")),
    ("script file", re.compile(CMD + r"(?:(?:python[0-9.]*|node|bash|sh|zsh|perl|ruby|deno|bun|tsx|ts-node)\s+(?:-\S+\s+)*(?P<f>[^\s;&|-]\S*)"
                                     r"|(?P<g>\./\S+))")),
    ("make", re.compile(CMD + r"g?make" + END)),
    ("package script", re.compile(CMD + r"(?:(?:npm|pnpm|yarn|bun)\s+(?:run|run-script|exec|dlx|x)\b|npx\b)")),
    ("find + xargs/-exec", re.compile(r"\bfind\b[^\n;&]*(?:\|\s*xargs\b|-exec(?:dir)?\b|-ok\b)")),
    ("nested claude", re.compile(CMD + r"claude" + END)),
]


def epoch_utc(ts):
    try:
        return calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
    except (TypeError, ValueError):
        return None


def epoch_local(ts):
    try:
        return time.mktime(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
    except (TypeError, ValueError):
        return None


def unparsed_kind(cmd):
    for name, rx in UNPARSED:
        for m in rx.finditer(cmd):
            if name == "script file":
                f = m.group("f") or m.group("g")
                if not re.search(r"\.(py|js|mjs|cjs|ts|sh|bash|pl|rb)$", f.strip("'\"")) and not m.group("g"):
                    continue
                if os.path.realpath(os.path.expanduser(f.strip("'\""))).startswith(SK + os.sep):
                    continue                 # the skill's own scripts: exempt from the guard by design, listed elsewhere when they matter
            return name
    return None


def is_user_turn(e):
    if e.get("type") != "user" or e.get("isMeta") or e.get("isCompactSummary"):
        return False
    c = (e.get("message") or {}).get("content")
    if isinstance(c, list):
        if any(isinstance(x, dict) and x.get("type") == "tool_result" for x in c):
            return False
        c = " ".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
    return isinstance(c, str) and bool(c.strip()) and not c.lstrip().startswith("[Request interrupted")


def read_entries(path):
    """[(line no, entry)] of the user / assistant entries; other kinds (api-request-blob repeats tool_use blocks) are left out."""
    out = []
    with open(path, errors="replace") as f:
        for n, l in enumerate(f, 1):
            try:
                e = json.loads(l)
            except ValueError:
                continue
            if isinstance(e, dict) and e.get("type") in ("user", "assistant"):
                out.append((n, e))
    return out


def blocks(e, kind):
    c = (e.get("message") or {}).get("content")
    return [x for x in c if isinstance(x, dict) and x.get("type") == kind] if isinstance(c, list) else []


def log_lines(state, tid):
    """[(ts, session, action, detail)] of this ticket's delivery.log lines."""
    out = []
    try:
        text = open(os.path.join(state, "delivery.log"), errors="replace").read()
    except OSError:
        return out
    for l in text.splitlines():
        p = [x.strip() for x in l.split(" | ")]
        if len(p) >= 5 and p[1].startswith("session=") and p[2] == "ticket=" + tid:
            out.append((p[0], p[1][8:], p[3], " | ".join(p[4:])))
    return out


def marker_info(state, tid, ticket):
    """(problem or None, approved epoch or None, line to print)."""
    rec, why = plan_lock.read_marker(state, tid)
    cur, cwhy = plan_lock.plan_hash(ticket)
    curs = cur[:12] if cur else "none (%s)" % cwhy
    if why:
        return "untrusted marker: %s" % why, None, "marker: untrusted (%s) | current plan %s" % (why, curs)
    if rec is None:
        return "no approval marker", None, "marker: none | current plan %s" % curs
    approved = None
    try:
        fd = os.open(plan_lock.marker_path(state, tid), os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd) as f:
            m = re.search(r"^approved=(\S+)$", f.read(4096), re.M)
        approved = m.group(1) if m else None
    except OSError:
        pass
    line = "marker: sha256 %s approved %s | current plan %s" % (rec[:12], approved or "?", curs)
    if cur != rec:
        return "the marker hash %s differs from the current plan %s" % (rec[:12], curs), epoch_local(approved), line + ": MISMATCH"
    return None, epoch_local(approved), line + ": match"


def main(argv):
    ap = argparse.ArgumentParser(prog="lock-trace.sh")
    ap.add_argument("ticket")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--session", required=True, help="this session's id")
    ap.add_argument("--projects", default=DEFAULT_PROJECTS, help="tests only; any other value is listed")
    a = ap.parse_args(argv)
    if not plan_lock.ID_RE.fullmatch(a.ticket):
        print("lock-trace: %r is not a plain ticket id" % a.ticket, file=sys.stderr)
        return 2
    repo = os.path.realpath(a.repo)
    if subprocess.run(["git", "-C", repo, "rev-parse"], capture_output=True).returncode != 0:
        print("lock-trace: not a git repo: %s" % repo, file=sys.stderr)
        return 2
    home, state, key = ticket_ctl.state_dir(repo)
    ticket = ticket_ctl.ticket_text(state, a.ticket)
    if ticket is None:
        print("lock-trace: no ticket file tickets/%s.md" % a.ticket, file=sys.stderr)
        return 2
    wts = os.path.join(repo, ".claude", "worktrees") + os.sep
    log = log_lines(state, a.ticket)
    sids = []
    for s in [x[1] for x in log] + [a.session]:
        if s not in sids and s != "-":
            sids.append(s)
    listed = []

    def lst(kind, text):
        listed.append("%-10s %s" % (kind, text))

    projects = os.path.realpath(a.projects)
    if projects != os.path.realpath(DEFAULT_PROJECTS):
        lst("projects", "non-default --projects %s (stage 8 never passes it)" % projects)

    mprob, mepoch, mline = marker_info(state, a.ticket, ticket)
    if mprob:
        lst("marker", mprob)
    info, approves, found = [], [], 0
    for sid in sids:
        if not SID_RE.fullmatch(sid):
            lst("session", "%r is not a plain session id (%s): not looked up" % (sid[:80], "--session" if sid == a.session else "delivery.log"))
            continue
        mains = sorted(glob.glob(os.path.join(glob.escape(projects), "*", glob.escape(sid) + ".jsonl")))
        subs = sorted(glob.glob(os.path.join(glob.escape(projects), "*", glob.escape(sid), "subagents", "*.jsonl")))
        if not mains:
            lst("missing", "%s: no transcript %s/*/%s.jsonl" % (sid, projects, sid))
        found += len(mains)
        cwds = set()
        for path in mains + subs:
            sub = path in subs
            try:
                ents = read_entries(path)
            except OSError as e:
                lst("missing", "%s: cannot read %s (%s)" % (sid, path, e.strerror))
                continue
            where = "%s%s" % (sid[:8], "/" + os.path.basename(path)[:-6] if sub else "")
            errs = {x.get("tool_use_id") for _, e in ents for x in blocks(e, "tool_result") if x.get("is_error")}
            shown, shown_at, turn_since = None, None, False
            for n, e in ents:
                if not sub and e.get("cwd"):
                    cwds.add(e["cwd"])
                if is_user_turn(e) and not sub:
                    turn_since = True
                for t in blocks(e, "text"):
                    for m in HASH_SHOWN.finditer(t.get("text", "")):
                        if e.get("type") == "assistant":
                            shown, shown_at, turn_since = m.group(1), n, False
                for u in blocks(e, "tool_use"):
                    inp = u.get("input") or {}
                    text = json.dumps(inp, ensure_ascii=False)
                    ts = e.get("timestamp", "?")
                    at = "%s line %d %s" % (where, n, ts[:19])
                    if re.search(r"\bapprovals/|/approvals\b", text):
                        lst("approvals", "%s %s: %s" % (at, u.get("name"), text[:200]))
                    cmd = inp.get("command") if u.get("name") == "Bash" and isinstance(inp.get("command"), str) else None
                    if cmd is None:
                        continue
                    k = unparsed_kind(cmd)
                    if k and "lock-trace.sh" not in cmd:
                        ep = epoch_utc(ts)
                        tag = "%s%s" % (k, ", is_error" if u.get("id") in errs else "")
                        if mepoch is not None and ep is not None and ep >= mepoch:
                            info.append("after-marker %s [%s] %s" % (at, tag, cmd[:160]))
                        else:
                            lst("unparsed", "%s [%s] before the marker: %s" % (at, tag, cmd[:160]))
                    m = re.search(r"approve-plan\.sh\s+(\S+)(.*)", cmd)
                    if not m or m.group(1) != a.ticket or "--rework" in m.group(2):
                        continue
                    sm = re.search(r"--sha[= ]+['\"]?([0-9A-Fa-f]+)", m.group(2))
                    sha = sm.group(1).lower() if sm else None
                    probs = []
                    if sub:
                        probs.append("ran in a subagent")
                    if shown is None:
                        probs.append("no `plan hash` line in Claude's text before it")
                    else:
                        if sha != shown:
                            probs.append("--sha %s differs from the hash shown %s (line %d)" % (sha, shown, shown_at))
                        if not turn_since:
                            probs.append("approved without a user turn (hash shown at line %d)" % shown_at)
                    ok = u.get("id") not in errs
                    approves.append((sid, sha, ok, at))
                    if ok and sha and not any(act == "plan-approve" and det.startswith("sha256=" + sha) for _, _, act, det in log):
                        probs.append("no delivery.log plan-approve line with sha256=%s..." % sha)
                    if probs:
                        lst("approve", "%s --sha %s%s: %s" % (at, sha, "" if ok else " (is_error)", "; ".join(probs)))
                    else:
                        info.append("approve-ok   %s --sha %s = shown = delivery.log" % (at, sha))
        if mains:
            try:
                rec = open(os.path.join(home, "starts", sid)).read().strip() if not os.path.islink(os.path.join(home, "starts", sid)) else None
            except OSError:
                rec = None
            if rec is None:
                lst("start", "%s: no starts/%s record (or a symlink)" % (sid, sid))
            else:
                odd = sorted(c for c in cwds if not (os.path.realpath(c) + os.sep).startswith(rec.rstrip(os.sep) + os.sep)
                             and not (os.path.realpath(c) + os.sep).startswith(wts))
                if odd:
                    lst("start", "%s: started in %s; transcript cwd(s) outside it and outside the worktrees: %s" % (sid, rec, ", ".join(odd)))
    for ts, s, act, det in log:
        if act == "plan-approve":
            h = det[7:19] if det.startswith("sha256=") else "?"
            if not any(sha == h and ok for _, sha, ok, _ in approves):
                lst("approve", "delivery.log %s session=%s plan-approve sha256=%s...: no approve-plan.sh call for it in the scanned transcripts" % (ts, s, h))
    print("lock-trace %s: %d session(s) (delivery.log + current), %d main transcript(s) found" % (a.ticket, len(sids), found))
    print("transcripts: %s" % projects)
    print(mline)
    for l in listed:
        print(l)
    for l in info:
        print(l)
    print("%d line(s) listed" % len(listed))
    return 1 if listed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
