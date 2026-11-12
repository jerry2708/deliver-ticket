#!/usr/bin/env python3
"""scripts/guard-apply.sh <candidate> --repo <main checkout> [--session <id>]

The write of <state>/guard.json (the gate action of guard-write.sh; see its docstring). A separate entry script on purpose: the permission
`ask` rule is the full path of this script, so it matches however the arguments are spelled, and the prompt is the user's yes - there is no
--confirmed flag to pass by oneself. Validate and show the change first with `guard-write.sh diff`. Standard library only.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import guard_write  # noqa: E402


def main():
    ap = argparse.ArgumentParser(prog="guard-apply.sh")
    ap.add_argument("candidate")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--session", default="-")
    a = ap.parse_args()
    return guard_write.apply_candidate(a.candidate, a.repo, a.session)


if __name__ == "__main__":
    sys.exit(main())
