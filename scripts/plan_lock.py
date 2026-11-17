#!/usr/bin/env python3
"""Shared by the plan-approval writer (approve_plan.py) and the lock check (hooks, C8): the hash of a ticket's `## Plan` section and the safe read of
<state>/approvals/<ID>.plan. Pure functions, standard library only; nothing here writes.

The marker is `sha256=<hash>` + `approved=<ts>` + `session=<sid>`, valid while the hash equals the hash of the CURRENT plan section, so an edited plan re-locks by
itself. `approvals/` and the marker are refused (fail-closed: not valid, not read) when either is a symlink, not a plain directory / file, or not owned by the
user: a pre-planted link must not redirect the reader or the writer (plan.md, milestone 1c, section 3 and the C6 review).
"""
import hashlib
import os
import re

PLAN_HEAD = re.compile(r"^##[ \t]+Plan[ \t]*$")
ANY_H2 = re.compile(r"^##[ \t]")
FENCE = re.compile(r"^[ \t]*(```|~~~)")
ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")


def plan_section(text):
    """(normalised section text, problem). The section runs from the line `## Plan` to the next level-2 heading (headings inside a code fence do not count);
    LF line ends, trailing blanks stripped per line, leading / trailing blank lines dropped. Problem: no heading, more than one, or an empty section."""
    lines = (text or "").replace("\r\n", "\n").replace("\r", "\n").split("\n")
    heads, infence = [], False
    for i, ln in enumerate(lines):
        if FENCE.match(ln):
            infence = not infence
            continue
        if not infence and PLAN_HEAD.match(ln):
            heads.append(i)
    if len(heads) != 1:
        return None, ("the ticket file has no `## Plan` section" if not heads else "the ticket file has %d `## Plan` headings (exactly one is allowed)" % len(heads))
    body, infence = [], False
    for ln in lines[heads[0] + 1:]:
        if FENCE.match(ln):
            infence = not infence
        elif not infence and ANY_H2.match(ln):
            break
        body.append(ln.rstrip())
    while body and not body[0]:
        body.pop(0)
    while body and not body[-1]:
        body.pop()
    if not body:
        return None, "the `## Plan` section is empty"
    return "\n".join(body), None


def plan_hash(text):
    """(sha256 hex of the normalised plan section, problem)."""
    sec, why = plan_section(text)
    return (hashlib.sha256(sec.encode("utf-8")).hexdigest() if sec is not None else None), why


def _plain(path, want_dir):
    """None when `path` (lstat, no symlink followed) is a plain directory / file owned by this user, else the reason. A missing path is not a problem here."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return None
    except OSError as e:
        return "cannot stat %s (%s)" % (path, e.strerror)
    import stat
    if stat.S_ISLNK(st.st_mode):
        return "%s is a symlink" % path
    if (stat.S_ISDIR(st.st_mode) if want_dir else stat.S_ISREG(st.st_mode)) is False:
        return "%s is not a plain %s" % (path, "directory" if want_dir else "file")
    if st.st_uid != os.getuid():
        return "%s is not owned by this user" % path
    return None


def approvals_problem(state):
    """Reason the approvals directory cannot be trusted (symlink, not a directory, other owner), else None (also when it does not exist yet)."""
    return _plain(os.path.join(state, "approvals"), True)


def marker_path(state, tid):
    return os.path.join(state, "approvals", tid + ".plan")


def marker_problem(state, tid):
    return approvals_problem(state) or _plain(marker_path(state, tid), False)


def read_marker(state, tid):
    """(hash recorded in the marker or None, problem). None + no problem = no marker. Any problem means: treat the plan as NOT approved."""
    if not ID_RE.fullmatch(tid or ""):
        return None, "%r is not a plain ticket id" % tid
    why = marker_problem(state, tid)
    if why:
        return None, why
    try:
        fd = os.open(marker_path(state, tid), os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None, None
    except OSError as e:
        return None, "cannot open the marker (%s)" % e.strerror
    with os.fdopen(fd) as f:
        data = f.read(4096)
    m = re.search(r"^sha256=([0-9a-f]{64})$", data, re.M)
    return (m.group(1), None) if m else (None, "the marker has no sha256 line")


def plan_approved(state, tid, ticket_text):
    """(True, None) when a trusted marker exists and its hash equals the hash of the current plan section; else (False, reason)."""
    rec, why = read_marker(state, tid)
    if why:
        return False, why
    if rec is None:
        return False, "no approval marker for %s" % tid
    cur, why = plan_hash(ticket_text)
    if why:
        return False, why
    return (True, None) if cur == rec else (False, "the plan changed since it was approved")
