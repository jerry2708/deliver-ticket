#!/usr/bin/env python3
"""scripts/git-rename.sh <old> <new>   (run from the ticket's worktree directory)

`git -c core.hooksPath=/dev/null branch -m -- <old> <new>`, unsandboxed so that it can write the repo's refs, with the repo's own hooks off
(reference-transaction would otherwise run worktree code unsandboxed). <old> must be the branch checked out here AND the ticket's branch as recorded in
delivery.log (worktree-create.sh records it; this script records the new name): a bookkeeping script with no prompt must not repoint the record that
git-commit.sh trusts. See git_safe.py.
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
    rec = git_safe.recorded_branch(state, tid)
    if rec is None:
        git_safe.die("no branch is recorded for ticket %s in delivery.log (the project WorktreeCreate hook records it when it creates the worktree): "
                     "rename refused" % tid)
    if old != rec:
        git_safe.die("%r is not the branch recorded for ticket %s (%r): only the recorded branch is renamed" % (old, tid, rec))
    git_safe.check_config_origins(wt, repo, common)
    rc = git_safe.run_git(wt, "branch", "-m", "--", old, new)
    if rc == 0:
        git_safe.record_branch(state, tid, new)
    return rc


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
    import fixed_env      # C11e3: fixed PATH / HOME, only the kept variables, before anything runs
    fixed_env.apply()
    sys.exit(main(sys.argv[1:]))
