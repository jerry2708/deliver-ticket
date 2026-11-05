#!/usr/bin/env python3
"""Pre-existing failure or regression? Compare the failure lines of one check run on the base with the same check on the ticket.

usage: compare-failures.py <base-output.txt> <ticket-output.txt> [--root-base DIR] [--root-ticket DIR]
Prints `pre-existing` (in both), `new` (only on the ticket = regression) and `fixed` (only on the base).
Exit 0 = no new failure line, 1 = at least one new failure line, 2 = usage error.
Heuristic on text: it keeps lines that look like failures and strips what changes between runs (colours, durations,
the checkout path). When the tool's output does not look like that, compare by hand and say which lines you compared.
"""
import argparse
import re
import sys

FAIL = re.compile(r"error|fail|✖|✗|×|\bnot ok\b|\b404\b|cannot find|exception|assert", re.I)
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
DUR = re.compile(r"\b\d+(?:\.\d+)?\s?(?:ms|s|sec|seconds?)\b|\b\d{2}:\d{2}:\d{2}(?:\.\d+)?\b|\b\d{4}-\d{2}-\d{2}[T ][\d:.]+Z?\b")


def norm(text, root):
    out = set()
    for l in text.splitlines():
        l = ANSI.sub("", l)
        if root:
            l = l.replace(root.rstrip("/"), "<root>")
        l = DUR.sub("<t>", l).strip()
        if l and FAIL.search(l):
            out.add(re.sub(r"\s+", " ", l))
    return out


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("base")
    ap.add_argument("ticket")
    ap.add_argument("--root-base", default="")
    ap.add_argument("--root-ticket", default="")
    a = ap.parse_args(argv[1:])
    base = norm(open(a.base).read(), a.root_base)
    tick = norm(open(a.ticket).read(), a.root_ticket)
    for label, items in (("pre-existing", base & tick), ("new", tick - base), ("fixed", base - tick)):
        print("%s: %d" % (label, len(items)))
        for l in sorted(items):
            print("  " + l)
    return 1 if tick - base else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
