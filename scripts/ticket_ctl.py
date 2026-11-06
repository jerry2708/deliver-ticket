#!/usr/bin/env python3
"""session-map.sh and ticket-state.sh: the only writers (besides the bind / EnterWorktree hooks) of the session map and of
ticket closure. The guard (hooks/dtcore.py) blocks every other write to sessions/, <state>/closed/ and <state>/delivery.log.

  session-map.sh show   [<ID>] --session SID --repo R
  session-map.sh pause  <ID> [--after-stage8] --reason TEXT --session SID --repo R
        Release the session from <ID> without closing the ticket (the next `/deliver-ticket <ID> ...` prompt re-binds it).
        Allowed only while no code exists: the session has not entered a worktree (no `worktree=` line written by the
        EnterWorktree hook). With --after-stage8: also when the ticket file says `stage: 8`.
  session-map.sh bind   <ID> --reason TEXT --session SID --repo R
        Bind this session to <ID> by hand when the bind hook did not (stage 0 check 10 failed and the user said yes).
        Only ever adds protection; logged.
  session-map.sh rebind <old-token> <real-ID> --session SID --repo R
        The first word after /deliver-ticket was not the ticket ID: bind to the real ID (its ticket file must exist) and drop
        the token (its own ticket file must not exist, and no worktree may be recorded under it).
  ticket-state.sh done|cancelled <ID> --reason TEXT --session SID --repo R
        Close the ticket: marker <state>/closed/<ID>, `state:` line in the ticket file, one line in <state>/delivery.log.
        `done` needs `stage: 8` in the ticket file.
  ticket-state.sh reopen <ID> --reason TEXT --session SID --repo R
        Rename the marker (nothing is deleted), set `state: active`, un-pause the session. Only after the user said yes.
Every transition is logged to <state>/delivery.log: time | session | ticket | action | detail.
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys
import time

TOKEN_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
SID_RE = re.compile(r"[A-Za-z0-9._-]+")


def state_dir(repo):
    r = subprocess.run(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("not a git repo: %s" % repo)
    common = r.stdout.strip()
    p = common[:-5] if common.endswith("/.git") else common
    key = "%s-%s" % (os.path.basename(p), hashlib.sha1(p.encode()).hexdigest()[:8])
    home = os.path.realpath(os.environ.get("DELIVER_TICKET_HOME") or os.path.expanduser("~/.local/share/deliver-ticket"))
    return home, os.path.join(home, key), key


def read_map(home, sid):
    try:
        return [tuple(l.split("=", 1)) for l in open(os.path.join(home, "sessions", sid)).read().splitlines() if "=" in l]
    except OSError:
        return []


def write_map(home, sid, lines):
    d = os.path.join(home, "sessions")
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".%s.%d.tmp" % (sid, os.getpid()))
    with open(tmp, "w") as fh:
        fh.write("".join("%s=%s\n" % kv for kv in lines))
    os.replace(tmp, os.path.join(d, sid))


def log(state, sid, ticket, action, detail):
    os.makedirs(state, exist_ok=True)
    with open(os.path.join(state, "delivery.log"), "a") as f:
        f.write("%s | session=%s | ticket=%s | %s | %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), sid, ticket, action, detail.replace("\n", " ")))


def ticket_text(state, tid):
    try:
        return open(os.path.join(state, "tickets", tid + ".md")).read()
    except OSError:
        return None


def field(txt, name):
    m = re.search(r"^\s*%s:\s*(\S.*)$" % name, txt or "", re.M)
    return m.group(1).strip() if m else None


def set_state_line(txt, new):
    return re.sub(r"^(state:[ \t]*)(.*?)([ \t]*(?:<!--.*)?)$", lambda m: m.group(1) + new + m.group(3), txt, count=1, flags=re.M)


def main():
    ap = argparse.ArgumentParser(prog="ticket_ctl")
    ap.add_argument("tool", choices=["session-map", "ticket-state"])
    ap.add_argument("action")
    ap.add_argument("ids", nargs="*")
    ap.add_argument("--session")
    ap.add_argument("--repo")
    ap.add_argument("--reason", default="")
    ap.add_argument("--after-stage8", action="store_true")
    a = ap.parse_args()
    if not a.repo or not a.session or not SID_RE.fullmatch(a.session):
        sys.exit("need --repo <main checkout> and --session <session id>")
    for i in a.ids:
        if not TOKEN_RE.fullmatch(i):
            sys.exit("unsafe ticket id: %r" % i)
    home, state, key = state_dir(os.path.realpath(a.repo))
    if not os.path.isfile(os.path.join(state, "guard.json")):
        sys.exit("project not initialised (no guard.json in %s)" % state)
    lines = read_map(home, a.session)
    tokens = [v for k, v in lines if k == "ticket"]
    paused = [v for k, v in lines if k == "paused"]
    has_wt = any(k == "worktree" for k, v in lines)

    if a.tool == "session-map":
        if a.action == "show":
            for k, v in lines:
                print("%s=%s" % (k, v))
            if a.ids:
                ok = a.ids[0] in tokens and a.ids[0] not in paused
                print("bound to %s: %s" % (a.ids[0], "yes" if ok else "NO"))
                return 0 if ok else 1
            return 0
        if a.action == "bind":
            if len(a.ids) != 1 or not a.reason:
                sys.exit("bind <ID> --reason TEXT")
            t = a.ids[0]
            out = [] if any(k == "project" and v != key for k, v in lines) else list(lines)   # another project's map: start afresh
            if not any(k == "project" for k, v in out):
                out.insert(0, ("project", key))
            if ("ticket", t) not in out:
                out.append(("ticket", t))
            out = [kv for kv in out if kv != ("paused", t)]
            write_map(home, a.session, out)
            log(state, a.session, t, "bind", a.reason)
            print("session bound to %s by hand" % t)
            return 0
        if a.action == "pause":
            if len(a.ids) != 1 or not a.reason:
                sys.exit("pause <ID> --reason TEXT")
            t = a.ids[0]
            if t not in tokens:
                sys.exit("this session is not bound to %s" % t)
            if has_wt:
                txt = ticket_text(state, t)
                if not (a.after_stage8 and field(txt, "stage") == "8"):
                    sys.exit("refused: this session entered a worktree, so code exists; pause is only for the intake stops "
                             "(or --after-stage8 once the ticket file says `stage: 8`)")
            if t in paused:
                print("already paused"); return 0
            write_map(home, a.session, lines + [("paused", t)])
            log(state, a.session, t, "pause", a.reason)
            print("session released from %s (re-binds on the next /deliver-ticket %s prompt)" % (t, t))
            return 0
        if a.action == "rebind":
            if len(a.ids) != 2:
                sys.exit("rebind <old-token> <real-ID>")
            old, new = a.ids
            if old not in tokens:
                sys.exit("this session is not bound to %s" % old)
            if ticket_text(state, new) is None:
                sys.exit("refused: tickets/%s.md does not exist yet - create the ticket file first" % new)
            if ticket_text(state, old) is not None:
                sys.exit("refused: tickets/%s.md exists, so %s is a real ticket, not a wrong token" % (old, old))
            if any(k == "worktree" and os.path.basename(v.rstrip("/")) == old for k, v in lines):
                sys.exit("refused: a worktree is recorded under %s" % old)
            out = [kv for kv in lines if kv not in (("ticket", old), ("paused", old))]
            if ("ticket", new) not in out:
                out.append(("ticket", new))
            out = [kv for kv in out if kv != ("paused", new)]
            write_map(home, a.session, out)
            log(state, a.session, new, "rebind", "token %r -> %s" % (old, new))
            print("bound this session to %s (the word after /deliver-ticket was %r)" % (new, old))
            return 0
        sys.exit("unknown session-map action %s" % a.action)

    # ticket-state
    if len(a.ids) != 1 or not a.reason:
        sys.exit("ticket-state done|cancelled|reopen <ID> --reason TEXT")
    t = a.ids[0]
    txt = ticket_text(state, t)
    if txt is None:
        sys.exit("no ticket file tickets/%s.md" % t)
    closed_dir = os.path.join(state, "closed")
    marker = os.path.join(closed_dir, t)
    if a.action in ("done", "cancelled"):
        if os.path.exists(marker):
            print("already closed"); return 0
        if a.action == "done" and field(txt, "stage") != "8":
            sys.exit("refused: `done` needs `stage: 8` in the ticket file (stage 8 not reached)")
        os.makedirs(closed_dir, exist_ok=True)
        with open(marker, "w") as f:
            f.write("%s\nstate=%s\nsession=%s\nreason=%s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), a.action, a.session, a.reason.replace("\n", " ")))
        with open(os.path.join(state, "tickets", t + ".md"), "w") as f:
            f.write(set_state_line(txt, a.action))
        log(state, a.session, t, a.action, a.reason)
        print("ticket %s closed as %s" % (t, a.action))
        return 0
    if a.action == "reopen":
        if not os.path.exists(marker):
            sys.exit("ticket %s is not closed" % t)
        os.replace(marker, "%s.reopened-%s" % (marker, time.strftime("%Y%m%d-%H%M%S")))
        with open(os.path.join(state, "tickets", t + ".md"), "w") as f:
            f.write(set_state_line(txt, "active"))
        out = [kv for kv in lines if kv != ("paused", t)]
        if ("ticket", t) not in out:
            out.append(("ticket", t))
        if not any(k == "project" for k, v in out):
            out.insert(0, ("project", key))
        write_map(home, a.session, out)
        log(state, a.session, t, "reopen", a.reason)
        print("ticket %s reopened" % t)
        return 0
    sys.exit("unknown ticket-state action %s" % a.action)


if __name__ == "__main__":
    sys.exit(main())
