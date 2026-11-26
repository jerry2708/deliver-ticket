#!/usr/bin/env python3
"""scripts/lock-trace.sh <ID> --repo <main checkout> --session <current session id> [--projects DIR]   (read-only; runs inside the sandbox)

Stage 8 trace of the plan lock (plan.md, milestone 1c, section 3b): what the lock does NOT stop, read back from the session transcripts. A trace, not proof:
the transcripts live under ~/.claude/projects, which Claude can write (memory), so a missing line proves nothing.

Sessions: every `session=` of the ticket's lines in <state>/delivery.log, plus --session. Each one's transcript is <projects>/*/<sid>.jsonl (the main one) and
<projects>/*/<sid>/subagents/*.jsonl; a session with no main transcript is listed as missing, never skipped. Only `user` / `assistant` entries are read.
Listed (each counts):
  missing     a session id with no transcript file
  unparsed    a Bash call the hooks cannot see into (an interpreter reading its program from stdin: `python3 - <<EOF`, `bash < x`; python3 -c, node -e, perl / ruby -e, an interpreter or ./ running a script file that is not the skill's,
              make, npm / pnpm / yarn / bun run|exec|dlx, npx, find with xargs or -exec, a nested claude - but not `claude --version` / `claude -v` with
              nothing else in that simple command, judged per match: `claude --version; claude -p x` is still listed), made BEFORE the current marker
              was written (no marker: all of them). The ones after it are printed as `after-marker` and not counted (building runs make / npm run all
              the time). Each line shows the matched simple command (from the match to the next ; & | newline ) or backtick outside quotes, at most
              160 chars, "..." where cut), not the start of the whole command line.
  approvals   any tool call whose input names approvals/
  marker      no marker, an untrusted marker, or its hash differs from the current plan section
  approve     an approve-plan.sh <ID> --sha X call whose X differs from the last `plan hash` line in Claude's text before it, that has no such line, with no user
              turn between that line and the call ("approved without a user turn"), that ran in a subagent, or whose sha256 has no `plan-approve` line in
              delivery.log; and a `plan-approve` line in delivery.log that no scanned approve-plan.sh call explains
  session     a session id (--session or from delivery.log) that is not a plain id (no "/", no ".."): not looked up
  projects    --projects other than ~/.claude/projects (realpath): only the tests pass it; stage 8 never does
  verify      a call naming evidence/<ID>/verify.json that is not a plain verify-record.sh <ID> call (a Read tool call is printed as `read-verify`, not counted:
              stages 4 and 7 name the file, reading it forges nothing; a Bash `cat` is counted, it can carry a redirect); and an existing evidence/<ID>/verify.json whose mtime is
              later (2 s slack) than the result of the last verify-record.sh <ID> call in the scanned transcripts, or with no such call at all ("verify.json not
              explained by verify-record.sh"). A trace too: `touch -t` forges an mtime.
  start       a session with no <state root>/starts/<sid> record, or whose transcript has a cwd that is neither under the record nor under <repo>/.claude/worktrees
  commit      (C11e2) a `<skill dir>/scripts/git-commit.sh` call whose previous tool call in the same transcript is not exactly
              `git diff --cached --stat=10000 --no-renames` (Bash, same cwd, not is_error, with output), or that ran in a subagent; a stat output that is not
              complete (no `N files changed` line, a count that differs from its file lines, a line that is not a file line: cut short = mismatch);
              stat file names (C-quoted names unquoted) that differ from the `files=` of the delivery.log `commit` line with that sha; a commit call with
              no sha in its output that is not is_error; a `commit` line no scanned call explains, one marked MISMATCH (git-commit.sh exit 3), one
              not parsed, and one whose commit is missing in the repo or whose tree / files there (diff-tree --root -r --no-renames) differ from the line.
              Log lines from before C11e2 (staged list, renames followed) may show a rename as a mismatch.
A user turn: a `user` entry that is not isMeta, not a compact summary, not a tool result, not "[Request interrupted...".
The last line: "N line(s) listed (exit 1 if > 0); M info line(s) above, not counted" (info = approve-ok, after-marker, read-verify).
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
CLAUDE_VERSION = re.compile(r"\s+(?:--version|-v)[ \t]*(?=$|[;&|)\n`])")   # `claude --version` / `-v` and nothing else in that simple command


GC_CALL = re.compile(r"\S*/scripts/git-commit\.sh\s")
STAT_CMD = "git diff --cached --stat=10000 --no-renames"
STAT_SUMMARY = re.compile(r"\s*(\d+) files? changed(?:, \d+ insertions?\(\+\))?(?:, \d+ deletions?\(-\))?\s*")
COMMIT_OUT = re.compile(r"^\[[^\]\n]* ([0-9a-f]{7,64})\]", re.M)          # git commit's first line: [<branch> (root-commit) <short sha>] <subject>
LOG_COMMIT = re.compile(r"([0-9a-f]{40,64}) branch=(\S+) tree=([0-9a-f]{40,64})( MISMATCH .*?)? files=(\[.*\])")
C_ESC = {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13, '"': 34, "\\": 92}


def unquote(name):
    """git's C-style quoted path ("sp\\303\\251.txt") back to the name; an unquoted name is returned as is."""
    if len(name) < 2 or name[0] != '"' or name[-1] != '"':
        return name
    body, out, i = name[1:-1], bytearray(), 0
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            d = body[i + 1]
            if d in "01234567" and re.fullmatch(r"[0-7]{3}", body[i + 1:i + 4]):
                out.append(int(body[i + 1:i + 4], 8)); i += 4; continue
            if d in C_ESC:
                out.append(C_ESC[d]); i += 2; continue
        out += c.encode("utf-8", "surrogateescape"); i += 1
    return out.decode("utf-8", "surrogateescape")


def parse_stat(text):
    """(file names, problem or None) of a `git diff --stat` output; a problem when it is not complete."""
    lines = [l for l in text.splitlines() if l.strip()]
    names = []
    for i, l in enumerate(lines):
        m = STAT_SUMMARY.fullmatch(l)
        if m:
            n = int(m.group(1))
            if n != len(names):
                return names, "%d files changed but %d file line(s) (cut short?)" % (n, len(names))
            return names, None                       # lines after the summary (a harness note) are not part of the stat
        if " | " not in l:
            return names, "line %d is not a file line (cut short?): %s" % (i + 1, l.strip()[:80])
        left = l.rsplit(" | ", 1)[0]
        names.append(unquote((left[1:] if left.startswith(" ") else left).rstrip(" ")))
    return names, ("empty output" if not lines else "no `N files changed` line (cut short?)")


def result_text(x):
    c = x.get("content")
    if isinstance(c, list):
        return "\n".join(y.get("text", "") for y in c if isinstance(y, dict) and y.get("type") == "text")
    return c if isinstance(c, str) else ""


def git_out(repo, *a):
    r = subprocess.run(["git", "-C", repo] + list(a), capture_output=True)
    return r.stdout.decode("utf-8", "surrogateescape") if r.returncode == 0 else None


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
    """(kind, the matched simple command for display) or (None, None)."""
    for name, rx in UNPARSED:
        for m in rx.finditer(cmd):
            if name == "script file":
                f = m.group("f") or m.group("g")
                if not re.search(r"\.(py|js|mjs|cjs|ts|sh|bash|pl|rb)$", f.strip("'\"")) and not m.group("g"):
                    continue
                if os.path.realpath(os.path.expanduser(f.strip("'\""))).startswith(SK + os.sep):
                    continue                 # the skill's own scripts: exempt from the guard by design, listed elsewhere when they matter
            if name == "nested claude" and CLAUDE_VERSION.match(cmd, m.end()):
                continue                     # `claude --version` alone prints a version (DRY-01 stage 0); keep scanning the other matches
            return name, shown_cmd(cmd, m)
    return None, None


def cmd_end(cmd, i):
    """Index of the end of the simple command running at i, for display: ; newline | & ) or a backtick outside quotes, but not the & of 2>&1 / &> / >&.
    A display helper only: no parser (no heredocs, no nested $( ) depth)."""
    q = None
    while i < len(cmd):
        c = cmd[i]
        if q:
            if c == "\\" and q == '"':
                i += 1
            elif c == q:
                q = None
        elif c == "\\":
            i += 1
        elif c in "'\"":
            q = c
        elif c in ";\n|)`" or (c == "&" and cmd[i - 1:i] not in ("<", ">") and cmd[i + 1:i + 2] != ">"):
            return i
        i += 1
    return len(cmd)


def shown_cmd(cmd, m):
    """The simple command the match sits in: from the match (leading separator and blanks dropped) to the next command end, at most 160 chars."""
    start = m.start()
    while start < m.end() and cmd[start] in ";&|(\n`$ \t":
        start += 1
    text = cmd[start:cmd_end(cmd, m.end())].strip()
    if len(text) > 160:
        text = text[:160] + "..."
    return ("..." if cmd[:start].strip() else "") + text


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


def commit_call(u, cwd, before, sub, at, errs, outs):
    """{at, sha (short, from the output) or None, ok, problems, stat names or None} of one git-commit.sh call."""
    probs, names = [], None
    if sub:
        probs.append("ran in a subagent")
    if before is None:
        probs.append("no tool call before it in this transcript")
    else:
        pu, pcwd, pn = before
        pcmd = (pu.get("input") or {}).get("command")
        if pu.get("name") != "Bash" or not isinstance(pcmd, str) or pcmd.strip() != STAT_CMD:
            probs.append("the call before it (line %d) is not exactly `%s`: %s %s" % (pn, STAT_CMD, pu.get("name"), str(pcmd or "")[:100]))
        else:
            if pcwd != cwd:
                probs.append("the stat ran in %s, the commit in %s" % (pcwd, cwd))
            if pu.get("id") in errs:
                probs.append("the stat call (line %d) is_error" % pn)
            names, sp = parse_stat(outs.get(pu.get("id"), ""))
            if sp:
                probs.append("stat output (line %d): %s" % (pn, sp))
                names = None
    out = outs.get(u.get("id"), "")
    m = COMMIT_OUT.search(out)
    ok = u.get("id") not in errs
    if not m and ok:
        probs.append("no commit sha in its output")
    return {"at": at, "sha": m.group(1) if m else None, "ok": ok, "probs": probs, "names": names}


def check_commits(repo, log, calls, lst, info):
    """Calls vs delivery.log `commit` lines vs the repo (C11e2)."""
    lines = []
    for ts, s, act, det in log:
        if act != "commit":
            continue
        m = LOG_COMMIT.fullmatch(det)
        if not m:
            lst("commit", "delivery.log %s session=%s commit line not parsed: %s" % (ts, s, det[:160]))
            continue
        try:
            files = json.loads(m.group(5))
        except ValueError:
            files = None
        lines.append({"ts": ts, "s": s, "sha": m.group(1), "tree": m.group(3), "odd": m.group(4), "files": files, "used": False})
    for c in calls:
        if c["sha"] is None:
            if c["probs"]:
                lst("commit", "%s git-commit.sh: %s" % (c["at"], "; ".join(c["probs"])))
            else:
                info.append("commit-none  %s git-commit.sh is_error, no commit made" % c["at"])
            continue
        hits = [l for l in lines if l["sha"].startswith(c["sha"])]
        probs = list(c["probs"])
        if not hits:
            probs.append("no delivery.log commit line for %s" % c["sha"])
        for l in hits:
            l["used"] = True
            if c["names"] is not None and l["files"] is not None and sorted(c["names"]) != sorted(l["files"]):
                miss = sorted(set(l["files"]) - set(c["names"]))
                extra = sorted(set(c["names"]) - set(l["files"]))
                probs.append("stat shown != committed files (%d shown, %d logged); committed, not shown: %s; shown, not committed: %s"
                             % (len(c["names"]), len(l["files"]), json.dumps(miss[:5]) + ("..." if len(miss) > 5 else ""),
                                json.dumps(extra[:5]) + ("..." if len(extra) > 5 else "")))
        if probs:
            lst("commit", "%s git-commit.sh %s%s: %s" % (c["at"], c["sha"], "" if c["ok"] else " (is_error)", "; ".join(probs)))
        else:
            info.append("commit-ok    %s %s: stat shown = delivery.log (%d file(s))" % (c["at"], c["sha"], len(c["names"])))
    for l in lines:
        at = "delivery.log %s session=%s commit %s" % (l["ts"], l["s"], l["sha"][:12])
        if not l["used"]:
            lst("commit", "%s: no git-commit.sh call for it in the scanned transcripts" % at)
        if l["odd"]:
            lst("commit", "%s: logged as%s (git-commit.sh exit 3)" % (at, l["odd"]))
        if l["files"] is None:
            lst("commit", "%s: files= is not a JSON list" % at)
        if git_out(repo, "rev-parse", "-q", "--verify", l["sha"] + "^{commit}") is None:
            lst("commit", "%s: no such commit in the repo" % at)
            continue
        tree = (git_out(repo, "rev-parse", l["sha"] + "^{tree}") or "").strip()
        files = (git_out(repo, "diff-tree", "--root", "-r", "--no-commit-id", "--no-renames", "--name-only", "-z", l["sha"]) or "").split("\0")[:-1]
        if tree != l["tree"]:
            lst("commit", "%s: tree in the repo %s, logged %s" % (at, tree[:12], l["tree"][:12]))
        if l["files"] is not None and sorted(files) != sorted(l["files"]):
            lst("commit", "%s: files in the repo differ from the log (%d vs %d)" % (at, len(files), len(l["files"])))


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
    info, approves, found, vr_ends, commit_calls = [], [], 0, [], []
    vfile = "evidence/%s/verify.json" % a.ticket
    vr_call = re.compile(r"\S*/scripts/verify-record\.sh\s+%s(?:\s+[^;&|<>`$()\n]*)?" % re.escape(a.ticket))      # one plain call, nothing chained
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
            done_at = {x.get("tool_use_id"): e.get("timestamp") for _, e in ents for x in blocks(e, "tool_result")}
            outs = {x.get("tool_use_id"): result_text(x) for _, e in ents for x in blocks(e, "tool_result")}
            prev = None
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
                    before, prev = prev, (u, e.get("cwd"), n)
                    if u.get("name") == "Bash" and isinstance(inp.get("command"), str) and GC_CALL.match(inp["command"].strip() + " "):
                        commit_calls.append(commit_call(u, e.get("cwd"), before, sub, at, errs, outs))
                    if re.search(r"\bapprovals/|/approvals\b", text):
                        lst("approvals", "%s %s: %s" % (at, u.get("name"), text[:200]))
                    vr = u.get("name") == "Bash" and isinstance(inp.get("command"), str) and vr_call.fullmatch(inp["command"].strip())
                    if vr:
                        end = epoch_utc(done_at.get(u.get("id")) or ts)
                        if end is not None:
                            vr_ends.append(end)
                    elif vfile in text and u.get("name") == "Read":
                        info.append("read-verify  %s Read %s" % (at, inp.get("file_path", "")))
                    elif vfile in text:
                        lst("verify", "%s %s names %s: %s" % (at, u.get("name"), vfile, text[:200]))
                    cmd = inp.get("command") if u.get("name") == "Bash" and isinstance(inp.get("command"), str) else None
                    if cmd is None:
                        continue
                    k, kcmd = unparsed_kind(cmd)
                    if k and "lock-trace.sh" not in cmd:
                        ep = epoch_utc(ts)
                        tag = "%s%s" % (k, ", is_error" if u.get("id") in errs else "")
                        if mepoch is not None and ep is not None and ep >= mepoch:
                            info.append("after-marker %s [%s] %s" % (at, tag, kcmd))
                        else:
                            lst("unparsed", "%s [%s] before the marker: %s" % (at, tag, kcmd))
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
    vpath = os.path.join(state, "evidence", a.ticket, "verify.json")
    if os.path.lexists(vpath):
        mt = os.lstat(vpath).st_mtime
        if not vr_ends:
            lst("verify", "%s exists, but no verify-record.sh %s call in the scanned transcripts: verify.json not explained by verify-record.sh" % (vpath, a.ticket))
        elif mt > max(vr_ends) + 2:
            lst("verify", "%s changed at %s, after the last verify-record.sh %s call ended (%s): verify.json not explained by verify-record.sh"
                % (vpath, time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(mt)), a.ticket, time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(max(vr_ends)))))
    check_commits(repo, log, commit_calls, lst, info)
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
    print("%d line(s) listed (exit 1 if > 0); %d info line(s) above, not counted" % (len(listed), len(info)))
    return 1 if listed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
