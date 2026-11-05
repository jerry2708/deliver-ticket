#!/usr/bin/env python3
"""Tier floor for a ticket (stage 1/2/3/rework). Usage:
  classify.py --guard <guard.json> [--files F ...] [--lines N] [--acs N] [--labels L,L]
              [--type docs|wording|tests|refactor|bug|feature|hotfix] [--open-questions N] [--core-waiting]
              [--judged CATEGORY ...]   categories Claude judged "yes" (can only raise the floor)
              [--new-dep]               a new dependency is named by the ticket/plan
Prints JSON {"floor": "A|B|C", "by_criterion": {...}, "reasons": [...]}; floor = highest criterion.
It only sets a floor from what it is given: no path match is NOT "no risk" - Claude judges every
category too. `risk.exclude` globs (test files) are ignored for every category. Lines exclude lockfiles, generated code and tests (caller's job). Exit 2 on bad input.
"""
import argparse
import json
import re
import sys

ORDER = "ABC"


def glob_re(g):
    out, i = "", 0
    while i < len(g):
        if g.startswith("**/", i):
            out += "(?:.*/)?"; i += 3
        elif g.startswith("**", i):
            out += ".*"; i += 2
        elif g[i] == "*":
            out += "[^/]*"; i += 1
        elif g[i] == "?":
            out += "[^/]"; i += 1
        else:
            out += re.escape(g[i]); i += 1
    return re.compile("^" + out + "$")


def match(path, globs):
    p = path.lstrip("./")
    return any(glob_re(g.lstrip("./")).match(p) for g in globs)


def hi(a, b):
    return a if ORDER.index(a) >= ORDER.index(b) else b


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--guard", required=True)
    ap.add_argument("--files", nargs="*", default=[])
    ap.add_argument("--lines", type=int)
    ap.add_argument("--acs", type=int)
    ap.add_argument("--labels", default="")
    ap.add_argument("--type", choices=["docs", "wording", "tests", "refactor", "bug", "feature", "hotfix"])
    ap.add_argument("--open-questions", type=int, default=0)
    ap.add_argument("--core-waiting", action="store_true")
    ap.add_argument("--judged", nargs="*", default=[])
    ap.add_argument("--new-dep", action="store_true")
    a = ap.parse_args()
    try:
        g = json.load(open(a.guard))
        risk = g["risk"]
        cats, th = risk["categories"], risk["thresholds"]
    except (OSError, ValueError, KeyError) as e:
        print("classify: cannot use guard.json: %s" % e, file=sys.stderr)
        return 2
    excl = risk.get("exclude", [])      # globs (test files) that never count as a risk path
    reasons, by = [], {}

    r = "A"
    for name, globs in cats.items():
        if globs == "N/A":
            continue
        hit = [f for f in a.files if not match(f, excl) and match(f, globs)]
        if hit:
            r = "C"
            reasons.append("risk: %s matches %s" % (name, ", ".join(hit[:3])))
    if a.new_dep:
        r = "C"; reasons.append("risk: new dependency")
    lab = [l for l in a.labels.split(",") if l and l in risk.get("labels", [])]
    if lab:
        r = "C"; reasons.append("risk: label %s" % ",".join(lab))
    for c in a.judged:
        r = "C"; reasons.append("risk: Claude judged %s = yes" % c)
    if a.type == "hotfix":
        r = "C"; reasons.append("risk: hotfix")
    by["risk"] = r

    s = None
    if a.lines is not None or a.files or a.acs is not None:
        nf, nl, na = len(a.files), a.lines or 0, a.acs or 0
        if nf <= th["s_files"] and na <= th["s_acs"] and nl <= th["s_lines"]:
            s = "A"
        elif nf <= th["m_files"] and nl <= th["m_lines"]:
            s = "B"
        else:
            s = "C"; reasons.append("size L (%d files, %d lines): plan proposes splitting" % (nf, nl))
        reasons.append("size %s (%d files, %d lines, %d ACs)" % ({"A": "S", "B": "M", "C": "L"}[s], nf, nl, na))
        by["size"] = s

    c = "C" if a.core_waiting else ("B" if a.open_questions else "A")
    by["clarity"] = c
    if c != "A":
        reasons.append("clarity: %s" % ("core AC waiting for an answer" if a.core_waiting else "%d open question(s)" % a.open_questions))

    t = {"docs": "A", "wording": "A", "tests": "A", "refactor": "A", "bug": "B", "feature": "B", "hotfix": "C"}.get(a.type)
    if t:
        by["type"] = t
        reasons.append("type %s -> %s" % (a.type, t))

    floor = "A"
    for v in by.values():
        floor = hi(floor, v)
    print(json.dumps({"floor": floor, "by_criterion": by, "reasons": reasons}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
