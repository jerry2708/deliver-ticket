#!/usr/bin/env python3
"""secret-scan.sh <ID> --guard <state>/guard.json - key-looking strings in a ticket's evidence and diff (stages 4 and 6). Read-only.

Scans: every regular file under <state>/evidence/<ID>/ (not symlinks, not .env* names), the lines the ticket adds (`git diff <base_branch>...HEAD`
and the uncommitted `git diff HEAD` in the ticket worktree) and the worktree's untracked files (not .env*, not git-ignored ones).
Prints one line per finding, `<where>:<line> <kind> <masked value>`: never a whole value (the first 4 characters and the length).
Exit 0 = nothing found, 1 = findings, 2 = usage / setup error.

C11h: replaces the stage-6 `grep -E '(sk-...|KEY=...)' <state>/evidence/...` - Claude Code 2.1.325 asks before a credential-pattern search in files outside
the session's working directories (probe, ~/.cache/dt-probes/c11h-probe-1), and grep prints the matched value into the conversation.
Runs inside the sandbox (not excluded) with an allow rule (install_hooks.SANDBOXED): no prompt. A heuristic: a clean result is not proof of no secret.
"""
import argparse
import json
import os
import re
import subprocess
import sys

KINDS = [
    ("private-key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}\b")),
    ("gitlab-token", re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}")),
    ("slack-token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
    ("stripe-key", re.compile(r"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{10,}")),
    ("api-key-sk", re.compile(r"\bsk-[A-Za-z0-9_-]{20,}")),
    ("google-api-key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
]
# NAME=value / NAME: "value" where the name says secret; the value must look like a literal, not a reference or placeholder
ASSIGN = re.compile(r"""\b([A-Za-z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY|ACCESS_?KEY)[A-Za-z0-9_]*)["']?\s*[:=]\s*["']?([^\s"',;)]{8,})""", re.I)
NOT_LITERAL = re.compile(r"^(?:process\.env|os\.environ|import\.meta\.env|env\.|\$\{|\$[A-Z_]|<|\{\{|%\(|z\.|string\b|number\b|undefined|null|true|false)|^(?:x+|\*+|changeme|example\S*|placeholder\S*|your[_-]\S*|dummy\S*|test\S*|redacted\S*)$", re.I)
MAX_BYTES = 5 * 1024 * 1024


def is_env_name(name):
    return os.path.basename(name).lower().startswith(".env")


def mask(v):
    return "%s... (%d chars)" % (v[:4], len(v))


def scan_line(text):
    out = []
    for kind, rx in KINDS:
        for m in rx.finditer(text):
            out.append((kind, m.group(0)))
    for m in ASSIGN.finditer(text):
        v = m.group(2)
        if NOT_LITERAL.search(v) or any(v in x for _, x in out):
            continue
        out.append(("assignment:" + m.group(1), v))
    return out


def git(wt, *a):
    return subprocess.run(["git", "-C", wt] + list(a), capture_output=True, text=True, errors="replace", timeout=60)


def diff_added(wt, args):
    """(path, new line number, text) for every added line of `git diff <args>`."""
    r = git(wt, "diff", "--no-color", "--no-ext-diff", "-U0", *args)
    if r.returncode != 0:
        raise RuntimeError("git diff %s failed: %s" % (" ".join(args), r.stderr.strip()[:300]))
    path, n = None, 0
    for l in r.stdout.splitlines():
        if l.startswith("+++ "):
            path = l[6:] if l.startswith("+++ b/") else None
        elif l.startswith("@@"):
            m = re.search(r"\+(\d+)", l)
            n = int(m.group(1)) if m else 0
        elif l.startswith("+") and path:
            yield path, n, l[1:]
            n += 1


def file_lines(path):
    if os.path.getsize(path) > MAX_BYTES:
        return None
    with open(path, "rb") as f:
        data = f.read()
    if b"\0" in data[:8192]:
        return None
    return data.decode("utf-8", "replace").splitlines()


def main():
    ap = argparse.ArgumentParser(prog="secret-scan.sh")
    ap.add_argument("ticket")
    ap.add_argument("--guard", required=True)
    a = ap.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", a.ticket):
        print("ticket id %r is not a plain id" % a.ticket, file=sys.stderr)
        return 2
    try:
        g = json.load(open(a.guard))
        repo, base_branch = g["repo_root"], g["base_branch"]
    except (OSError, ValueError, KeyError) as e:
        print("cannot read %s: %s" % (a.guard, e), file=sys.stderr)
        return 2
    wbase = os.path.realpath(os.path.join(repo, ".claude", "worktrees"))
    wt = os.path.realpath(os.path.join(wbase, a.ticket))
    if os.path.dirname(wt) != wbase or not os.path.isdir(wt):
        print("no worktree %s for ticket %s" % (os.path.join(wbase, a.ticket), a.ticket), file=sys.stderr)
        return 2
    edir = os.path.join(os.path.dirname(os.path.realpath(a.guard)), "evidence", a.ticket)
    findings, scanned, skipped = [], [], []
    if os.path.isdir(edir):
        for root, dirs, files in os.walk(edir):
            dirs[:] = sorted(d for d in dirs if not os.path.islink(os.path.join(root, d)))
            for fn in sorted(files):
                p = os.path.join(root, fn)
                rel = os.path.relpath(p, os.path.dirname(os.path.dirname(edir)))
                if os.path.islink(p) or not os.path.isfile(p) or is_env_name(fn):
                    skipped.append(rel)
                    continue
                lines = file_lines(p)
                if lines is None:
                    skipped.append(rel + " (binary or > 5 MB)")
                    continue
                scanned.append(rel)
                for i, l in enumerate(lines, 1):
                    findings += [(rel, i, k, v) for k, v in scan_line(l)]
    try:
        for label, args in (("diff %s...HEAD" % base_branch, [base_branch + "...HEAD"]), ("uncommitted", ["HEAD"])):
            for path, n, text in diff_added(wt, args):
                if is_env_name(path):
                    continue
                findings += [("%s: %s" % (label, path), n, k, v) for k, v in scan_line(text)]
            scanned.append(label)
        r = git(wt, "ls-files", "--others", "--exclude-standard", "-z")
        for rel in [x for x in r.stdout.split("\0") if x]:
            p = os.path.join(wt, rel)
            if is_env_name(rel) or os.path.islink(p) or not os.path.isfile(p):
                continue
            lines = file_lines(p)
            if lines is None:
                continue
            for i, l in enumerate(lines, 1):
                findings += [("untracked: %s" % rel, i, k, v) for k, v in scan_line(l)]
        scanned.append("untracked files")
    except (RuntimeError, OSError, subprocess.SubprocessError) as e:
        print("secret-scan: %s" % e, file=sys.stderr)
        return 2
    seen = set()
    for where, n, kind, v in findings:
        key = (where, n, kind, v)
        if key in seen:
            continue
        seen.add(key)
        print("%s:%d %s %s" % (where, n, kind, mask(v)))
    print("secret-scan %s: %d finding(s); scanned %s%s" % (a.ticket, len(seen), ", ".join(scanned) or "nothing",
                                                           ("; skipped " + ", ".join(skipped)) if skipped else ""))
    return 1 if seen else 0


if __name__ == "__main__":
    sys.exit(main())
