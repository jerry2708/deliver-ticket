#!/usr/bin/env python3
"""Static check of how the run-time instructions call the skill's scripts (1d step 4).

The Bash sandbox's excludedCommands and the permission ask / allow rules match the command TEXT, so a bookkeeping or gate script is called only as
`<skill dir>/scripts/<name>.sh ...` (nothing in front, absolute). This reads SKILL.md, init.md, stages/*.md and templates/* and fails when
  - a bookkeeping / gate script (install_hooks.BOOKKEEPING + GATES) is named as `scripts/<name>` without the `<skill dir>/` prefix, or with `bash` / `python3` in front;
  - `<skill dir>/scripts/<name>.sh`, made absolute, would not match an excludedCommands pattern of `install-hooks.sh project-sandbox-apply` (or, for a gate script,
    its user-level ask rule is missing);
  - `git -C <dir> push` or `git -C <dir> branch -m` is written (a `git -C` call stays sandboxed even when excluded);
  - `cd <dir> && git push|branch -m` (also `;`, `||`, `pushd`, inside a subshell) or an env assignment in front (`FOO=1 git push`) is written: the exclusion and the
    ask rule match the command text as a prefix, so the push would run sandboxed (probe `push_after_cd_stays_sandboxed`) or miss its ask rule.
Usage: lint_script_calls.py [skill root]      -> exit 1 and one line per violation
       lint_script_calls.py --text "<text>"   -> checks one string (used by run-docs-lint.sh to prove that bad forms are caught)
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
os.environ.setdefault("DT_SETTINGS", "/nonexistent")
import install_hooks as ih  # noqa: E402

NAMES = ih.BOOKKEEPING + ih.GATES
SK = ih.SKILL


def excluded_patterns():
    _, adds = ih.sandbox_plan("/r", "/s", [], False)
    return dict(adds)[("sandbox", "excludedCommands")]


def matches(cmd, pats):
    return any(cmd == p[:-2] or (p.endswith(" *") and cmd.startswith(p[:-1])) or cmd == p for p in pats)


def check(text, label):
    out = []
    pats = excluded_patterns()
    for n, line in enumerate(text.split("\n"), 1):
        for name in NAMES:
            for m in re.finditer(re.escape("scripts/" + name), line):
                prefix = line[:m.start()]
                if not prefix.endswith("<skill dir>/"):
                    out.append("%s:%d: %s must be called as <skill dir>/scripts/%s (found %r in front of scripts/)" % (label, n, name, name, prefix[-14:]))
                    continue
                before = prefix[:-len("<skill dir>/")].rstrip()
                if re.search(r"\b(bash|sh|zsh|python3?|env|xargs)\s*`?$", before):
                    out.append("%s:%d: %s has an interpreter or wrapper in front: %r" % (label, n, name, before[-24:]))
                if not matches(os.path.join(SK, "scripts", name) + " x", pats):
                    out.append("%s:%d: %s would not match any excludedCommands pattern" % (label, n, name))
        if re.search(r"git -C \S+ (push|branch -m)\b", line):
            out.append("%s:%d: `git -C <dir> push|branch -m` stays sandboxed even when excluded; use the plain command from the worktree directory" % (label, n))
        if re.search(r"\b(cd|pushd)\s+\S+\s*(&&|;|\|\|)\s*git (push|branch -m)\b", line):
            out.append("%s:%d: `cd <dir> && git push|branch -m` does not match the exclusion or the ask rule (command text prefix); make `cd` its own call, then the plain command" % (label, n))
        if re.search(r"(^|[\s`(;&|])[A-Za-z_][A-Za-z0-9_]*=\S*\s+git (push|branch -m)\b", line):
            out.append("%s:%d: an env assignment in front of `git push|branch -m` does not match the exclusion or the ask rule; call the plain command" % (label, n))
    return out


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--text":
        v = check(sys.argv[2], "text")
        print("\n".join(v))
        return 1 if v else 0
    root = sys.argv[1] if len(sys.argv) > 1 else ROOT
    files = [os.path.join(root, f) for f in ("SKILL.md", "init.md")] + sorted(glob.glob(root + "/stages/*.md")) + sorted(glob.glob(root + "/templates/*"))
    bad = []
    for f in files:
        if os.path.isfile(f):
            bad += check(open(f).read(), os.path.relpath(f, root))
    asks = set(ih.ASK)
    for g in ih.GATES:
        if "Bash(%s *)" % os.path.join(SK, "scripts", g) not in asks:
            bad.append("gate script %s has no user-level ask rule" % g)
    print("\n".join(bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
