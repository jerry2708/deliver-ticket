#!/usr/bin/env python3
"""scripts/plan-hash.sh <ID> --repo <main checkout>   (read-only; runs inside the sandbox)

Prints the first 12 hex digits of the hash of the ticket file's `## Plan` section (plan_lock.plan_hash), the same value approve-plan.sh requires as --sha.
Stage 2 shows it under the plan when asking for my yes, so the plan I read is the plan that gets locked: an edit between my yes and the script run changes
the hash and approve-plan.sh refuses. Exit 0 and the hash, or 2 and the reason. Standard library only.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import plan_lock  # noqa: E402
import ticket_ctl  # noqa: E402


def main(argv):
    ap = argparse.ArgumentParser(prog="plan-hash.sh")
    ap.add_argument("ticket")
    ap.add_argument("--repo", required=True)
    a = ap.parse_args(argv)
    if not plan_lock.ID_RE.fullmatch(a.ticket):
        print("plan-hash: %r is not a plain ticket id" % a.ticket, file=sys.stderr)
        return 2
    home, state, key = ticket_ctl.state_dir(os.path.realpath(a.repo))
    txt = ticket_ctl.ticket_text(state, a.ticket)
    if txt is None:
        print("plan-hash: no ticket file tickets/%s.md" % a.ticket, file=sys.stderr)
        return 2
    digest, why = plan_lock.plan_hash(txt)
    if why:
        print("plan-hash: %s" % why, file=sys.stderr)
        return 2
    print("plan hash %s" % digest[:12])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
