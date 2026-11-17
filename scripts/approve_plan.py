#!/usr/bin/env python3
"""scripts/approve-plan.sh <ID> --sha <12 hex> --repo <main checkout> --session <sid>
scripts/approve-plan.sh <ID> --rework --reason TEXT --repo <main checkout> --session <sid>

The only writer of <state>/approvals/<ID>.plan (the hooks and the sandbox deny every other route; C6). A GATE script: excluded from the sandbox and behind a
user-level permission ask rule on its full path, so the prompt is the user's yes to the plan. There is no --confirmed flag to pass by oneself.

  approve:  hash the ticket file's `## Plan` section (plan_lock.plan_hash); --sha is the first 12 hex digits of that hash as scripts/plan-hash.sh showed them to the user
            with the plan, and a mismatch (the plan was edited after the user said yes) is refused; then write the marker `sha256=` / `approved=` / `session=`. Refused when the ticket is
            closed, has no (or an empty, or a doubled) `## Plan` section, or when approvals/ or the marker is a symlink / not a plain object / not ours.
  --rework: rename the marker to <ID>.plan.rework-<ts> (nothing is deleted); the lock closes again until the plan is approved anew. Also used by reopen.
The marker is created with O_CREAT|O_EXCL|O_NOFOLLOW as a temporary file inside approvals/ and renamed over the marker. Logged to delivery.log with the hash.
Standard library only.
"""
import argparse
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import plan_lock  # noqa: E402
import ticket_ctl  # noqa: E402


def die(msg):
    print("approve-plan: %s" % msg, file=sys.stderr)
    return 2


def retire(state, tid, kind):
    """Rename an existing marker to <ID>.plan.<kind>-<ts>. (True, None) also when there is none; (False, reason) when the directory or the marker cannot be trusted
    (then nothing is renamed: an untrusted marker is not valid for the reader either)."""
    why = plan_lock.marker_problem(state, tid)
    if why:
        return False, why
    m = plan_lock.marker_path(state, tid)
    if not os.path.lexists(m):
        return True, None
    new = "%s.%s-%s" % (m, kind, time.strftime("%Y%m%d-%H%M%S"))
    n = 1
    while os.path.lexists(new):
        n += 1
        new = "%s.%s-%s-%d" % (m, kind, time.strftime("%Y%m%d-%H%M%S"), n)
    os.rename(m, new)
    return True, None


def write_marker(state, tid, digest, session):
    adir = os.path.join(state, "approvals")
    why = plan_lock.marker_problem(state, tid)
    if why:
        return why
    if not os.path.lexists(adir):
        os.mkdir(adir, 0o700)
        why = plan_lock.approvals_problem(state)           # re-check what we just made (a race with a planted link)
        if why:
            return why
    tmp = os.path.join(adir, ".%s.plan.%d.tmp" % (tid, os.getpid()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("sha256=%s\napproved=%s\nsession=%s\n" % (digest, time.strftime("%Y-%m-%dT%H:%M:%S"), session.replace("\n", " ")))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, plan_lock.marker_path(state, tid))
    return None


def main(argv):
    ap = argparse.ArgumentParser(prog="approve-plan.sh")
    ap.add_argument("ticket")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--session", default="-")
    ap.add_argument("--sha", help="first 12 hex digits of the plan hash shown to the user (plan-hash.sh); required to approve")
    ap.add_argument("--rework", action="store_true")
    ap.add_argument("--reason")
    a = ap.parse_args(argv)
    if not plan_lock.ID_RE.fullmatch(a.ticket):
        return die("%r is not a plain ticket id" % a.ticket)
    home, state, key = ticket_ctl.state_dir(os.path.realpath(a.repo))
    txt = ticket_ctl.ticket_text(state, a.ticket)
    if txt is None:
        return die("no ticket file tickets/%s.md" % a.ticket)
    if os.path.exists(os.path.join(state, "closed", a.ticket)):
        return die("ticket %s is closed" % a.ticket)
    if a.rework:
        if not a.reason:
            return die("--rework needs --reason TEXT")
        ok, why = retire(state, a.ticket, "rework")
        if not ok:
            return die(why)
        ticket_ctl.log(state, a.session, a.ticket, "plan-rework", a.reason)
        print("plan approval of %s retired (the lock closes until the plan is approved again)" % a.ticket)
        return 0
    digest, why = plan_lock.plan_hash(txt)
    if why:
        return die(why)
    if not a.sha or not re.fullmatch(r"[0-9a-f]{12}", a.sha):
        return die("--sha <12 hex digits> is required: the plan hash that plan-hash.sh showed you with the plan (now: %s)" % digest[:12])
    if digest[:12] != a.sha:
        return die("the plan changed since the hash %s was shown (it is %s now): show the plan and the new hash again and ask again" % (a.sha, digest[:12]))
    why = write_marker(state, a.ticket, digest, a.session)
    if why:
        return die(why)
    ticket_ctl.log(state, a.session, a.ticket, "plan-approve", "sha256=%s" % digest)
    print("plan of %s approved (sha256 %s): the worktree is writable; an edit of the plan section closes it again until you approve anew" % (a.ticket, digest[:12]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
