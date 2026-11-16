#!/usr/bin/env python3
"""scripts/git-rename.sh <old> <new>   (run from the ticket's worktree directory)

`git -c core.hooksPath=/dev/null branch -m -- <old> <new>`, unsandboxed so that it can write the repo's refs, with the repo's own hooks off
(reference-transaction would otherwise run worktree code unsandboxed). <old> must be the branch checked out here. See git_safe.py.
"""
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import git_safe  # noqa: E402


def main(argv):
    git_safe.scrub_env()
    git_safe.positional(argv, 2)
    old, new = argv
    repo, state, g, wt, tid, common = git_safe.ticket_context(os.getcwd())
    for n, what in ((old, "old name"), (new, "new name")):
        git_safe.branch_name(n, what)
        git_safe.not_protected(n, g)
    cur = git_safe.git(wt, "symbolic-ref", "--short", "-q", "HEAD").stdout.strip()
    if cur != old:
        git_safe.die("%r is not the branch checked out here (%r): only this ticket's own branch is renamed" % (old, cur or "detached"))
    git_safe.check_config_origins(wt, repo, common)
    return git_safe.run_git(wt, "branch", "-m", "--", old, new)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
