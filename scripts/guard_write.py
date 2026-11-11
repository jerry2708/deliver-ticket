#!/usr/bin/env python3
"""The only sanctioned writer of <state>/guard.json (the hooks block every other route, hooks/dtcore.py protected_state).

  guard-write.sh diff   <candidate> --repo <main checkout>
      Validate the candidate (scripts/validate-guard.py, repo_root / project_key must match --repo) and print a unified
      diff against the current guard.json (a missing or unreadable current file is said so). Writes nothing.
  guard-write.sh apply  <candidate> --repo <main checkout> --confirmed [--session <id>]
      Same checks, then: back up the current file as guard.json.prev-<UTC ts> (kept, never deleted; not when the content is
      identical), write the candidate atomically (temp file in the state dir + os.replace), append
      `guard-write | sha256=<hash>` to delivery.log, and rename the candidate to guard.candidate.applied-<UTC ts>.json so a
      stale candidate cannot be applied again. Without --confirmed nothing is written. --confirmed means the user said
      yes to the diff just shown (init.md); a skill script is exempt from the hooks, so this is a convention plus a log
      line, not a lock.
  guard-write.sh verify --repo <main checkout>
      Compare the sha256 of guard.json with the last logged guard-write line. Exit 0 = same; 1 = different (edited outside
      this script); 3 = no apply recorded (a guard.json written by v0.1 init has none: warn, apply an identical candidate to
      adopt it); 2 = no guard.json.

The candidate goes to <state>/guard.candidate.json: only the state dir stays writable when guard.json is unreadable.
Standard library only.
"""
import argparse
import difflib
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import ticket_ctl  # noqa: E402  (state_dir, log)

SHA_FIELD = re.compile(r"sha256=([0-9a-f]{64})")


def main_checkout(repo):
    r = subprocess.run(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("not a git repo: %s" % repo)
    c = r.stdout.strip()
    return os.path.realpath(c[:-5] if c.endswith("/.git") else c)


def load_candidate(path, repo, key):
    """(bytes, text) of a valid candidate, else exit with the reason."""
    if os.path.islink(path) or not os.path.isfile(path):
        sys.exit("candidate must be a regular file (not a symlink): %s" % path)
    if os.path.basename(path).lower() == "guard.json":
        sys.exit("candidate must not be named guard.json: write guard.candidate.json in the state dir")
    with open(path, "rb") as f:
        data = f.read()
    v = subprocess.run([sys.executable, "-I", os.path.join(HERE, "validate-guard.py"), path], capture_output=True, text=True)
    if v.returncode != 0:
        sys.exit("candidate is not a valid guard.json (validate-guard.py exit %d):\n%s" % (v.returncode, (v.stdout + v.stderr).rstrip()))
    with open(path, "rb") as f:
        if f.read() != data:
            sys.exit("candidate changed while it was checked - aborting")
    g = json.loads(data.decode("utf-8"))
    if os.path.realpath(g.get("repo_root", "")) != main_checkout(repo):
        sys.exit("candidate repo_root %r is not this project's main checkout %s" % (g.get("repo_root"), main_checkout(repo)))
    if g.get("project_key") != key:
        sys.exit("candidate project_key %r is not %s" % (g.get("project_key"), key))
    return data, data.decode("utf-8")


def current(state):
    p = os.path.join(state, "guard.json")
    try:
        with open(p, "rb") as f:
            return f.read()
    except OSError:
        return None


def main():
    ap = argparse.ArgumentParser(prog="guard-write.sh")
    ap.add_argument("action", choices=["diff", "apply", "verify"])
    ap.add_argument("candidate", nargs="?")
    ap.add_argument("--repo")
    ap.add_argument("--session", default="-")
    ap.add_argument("--confirmed", action="store_true")
    a = ap.parse_args()
    if not a.repo:
        sys.exit("need --repo <main checkout>")
    home, state, key = ticket_ctl.state_dir(os.path.realpath(a.repo))
    cur = current(state)

    if a.action == "verify":
        if cur is None:
            print("no guard.json in %s" % state)
            return 2
        sha = hashlib.sha256(cur).hexdigest()
        last = None
        try:
            for line in open(os.path.join(state, "delivery.log")):
                # <ts> | session=<id> | ticket=<id> | guard-write | sha256=<64 hex>: exactly five fields. ticket_ctl.log()
                # turns "|" inside a field into "/", so a --reason text cannot forge a line (a line with more fields is not one).
                f = line.rstrip("\n").split(" | ")
                m = SHA_FIELD.fullmatch(f[4]) if len(f) == 5 and f[3] == "guard-write" else None
                if m:
                    last = m.group(1)
        except OSError:
            pass
        if last is None:
            print("warn: no guard-write recorded for this guard.json (written by v0.1 init, or by hand) - sha256 %s" % sha)
            return 3
        if last != sha:
            print("MISMATCH: guard.json (sha256 %s) is not what guard-write.sh last wrote (%s) - it was edited another way" % (sha, last))
            return 1
        print("ok: guard.json is what guard-write.sh last wrote (sha256 %s)" % sha)
        return 0

    if not a.candidate:
        sys.exit("%s needs a candidate file" % a.action)
    data, text = load_candidate(a.candidate, os.path.realpath(a.repo), key)
    old = cur.decode("utf-8", "replace") if cur is not None else None

    if a.action == "diff":
        if old is None:
            print("# no current guard.json: new file")
            old = ""
        elif old == text:
            print("# identical to the current guard.json (apply only records its hash)")
        sys.stdout.writelines(difflib.unified_diff(old.splitlines(True), text.splitlines(True), "guard.json (current)", "guard.json (candidate)"))
        return 0

    if not a.confirmed:
        sys.exit("refused: apply needs --confirmed, after the user said yes to the diff (guard-write.sh diff)")
    os.makedirs(state, exist_ok=True)
    ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    target = os.path.join(state, "guard.json")
    if cur is not None and cur != data:
        prev = "%s.prev-%s" % (target, ts)
        n = 1
        while os.path.exists(prev):
            n += 1
            prev = "%s.prev-%s-%d" % (target, ts, n)
        shutil.copy2(target, prev)
        print("backup: %s" % prev)
    tmp = os.path.join(state, ".guard.json.%d.tmp" % os.getpid())
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, target)
    sha = hashlib.sha256(data).hexdigest()
    ticket_ctl.log(state, a.session, "-", "guard-write", "sha256=%s" % sha)
    done = os.path.join(os.path.dirname(os.path.realpath(a.candidate)), "guard.candidate.applied-%s.json" % ts)
    n = 1
    while os.path.exists(done):
        n += 1
        done = os.path.join(os.path.dirname(os.path.realpath(a.candidate)), "guard.candidate.applied-%s-%d.json" % (ts, n))
    os.replace(os.path.realpath(a.candidate), done)
    print("guard.json written (sha256 %s); candidate kept as %s" % (sha, done))
    return 0


if __name__ == "__main__":
    sys.exit(main())
