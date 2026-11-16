#!/usr/bin/env python3
"""verify-record.sh <ID> --guard <state>/guard.json [--timeout <sec>] - see the wrapper for the contract."""
import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys


def git(wt, *a):
    return subprocess.run(["git", "-C", wt] + list(a), capture_output=True, text=True, timeout=30)


def main():
    ap = argparse.ArgumentParser(prog="verify-record.sh")
    ap.add_argument("ticket")
    ap.add_argument("--guard", required=True)
    ap.add_argument("--timeout", type=int)
    a = ap.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", a.ticket):
        print("ticket id %r is not a plain id" % a.ticket, file=sys.stderr)
        return 2
    try:
        g = json.load(open(a.guard))
        v = g["verify"]
        repo = g["repo_root"]
    except (OSError, ValueError, KeyError) as e:
        print("cannot read %s: %s" % (a.guard, e), file=sys.stderr)
        return 2
    keys = v.get("on_push") or []
    if not keys:
        print("verify.on_push is empty: nothing to record (the push hook does not ask for a record)")
        return 0
    for k in keys:
        if not v.get(k):
            print("verify.on_push lists %r but verify.%s has no command" % (k, k), file=sys.stderr)
            return 2
    base = os.path.realpath(os.path.join(repo, ".claude", "worktrees"))
    wt = os.path.realpath(os.path.join(base, a.ticket))
    if os.path.dirname(wt) != base or not os.path.isdir(wt):
        print("no worktree %s for ticket %s" % (os.path.join(base, a.ticket), a.ticket), file=sys.stderr)
        return 2
    st = git(wt, "status", "--porcelain")
    if st.returncode != 0 or st.stdout.strip():
        print("the worktree is not clean (or git failed): commit or stash everything, untracked files included, so the record describes the committed tree.\n%s" % st.stdout[:600], file=sys.stderr)
        return 2
    tree = git(wt, "rev-parse", "HEAD^{tree}").stdout.strip()
    head = git(wt, "rev-parse", "HEAD").stdout.strip()
    timeout = a.timeout or int(v.get("timeout_sec") or 300)
    results, failed = {}, False
    for k in keys:
        try:
            p = subprocess.run(v[k], shell=True, cwd=wt, capture_output=True, text=True, timeout=timeout)
            rc, out = p.returncode, (p.stdout or "") + (p.stderr or "")
        except subprocess.TimeoutExpired:
            rc, out = 124, "timed out after %ss" % timeout
        results[k] = {"rc": rc, "cmd_sha256": hashlib.sha256(v[k].encode()).hexdigest()}
        print("verify %s: exit %s" % (k, rc))
        if rc != 0:
            failed = True
            print("\n".join(out.splitlines()[-40:]))
    if git(wt, "diff", "--quiet", "HEAD").returncode != 0 or git(wt, "rev-parse", "HEAD^{tree}").stdout.strip() != tree:
        print("the verify commands changed tracked files (or HEAD): no record written. Commit or revert that, then run again.", file=sys.stderr)
        return 2
    edir = os.path.join(os.path.dirname(os.path.realpath(a.guard)), "evidence", a.ticket)
    os.makedirs(edir, exist_ok=True)
    rec = {"version": 1, "id": a.ticket, "tree": tree, "head": head, "results": results,
           "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    tmp = os.path.join(edir, ".verify.json.tmp")
    with open(tmp, "w") as f:
        json.dump(rec, f, indent=1)
        f.write("\n")
    os.replace(tmp, os.path.join(edir, "verify.json"))
    print("recorded %s (tree %s)%s" % (os.path.join(edir, "verify.json"), tree[:10], "; at least one check FAILED: the push stays blocked" if failed else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
