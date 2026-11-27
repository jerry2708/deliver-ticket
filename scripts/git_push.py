#!/usr/bin/env python3
"""scripts/git-push.sh <remote> <branch>   (run from the ticket's worktree directory)

The only way Claude pushes: `git -c core.hooksPath=/dev/null push -- <remote> HEAD:refs/heads/<branch>`, unsandboxed, behind a permission ask rule on this
script's full path (the user's yes). See git_safe.py: it validates every argument itself. The verify record (C4) must cover HEAD. Standard library only.
"""
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import git_safe  # noqa: E402


def main(argv):
    git_safe.scrub_env()
    git_safe.positional(argv, 2)
    remote, branch = argv
    repo, state, g, wt, tid, common = git_safe.ticket_context(os.getcwd())
    git_safe.branch_name(branch)
    git_safe.not_protected(branch, g)
    if remote in g["remotes"]["forbidden"] or remote not in g["remotes"]["allowed"]:
        git_safe.die("remote %r is not in the allowed list %s" % (remote, g["remotes"]["allowed"]))
    names = git_safe.git(wt, "remote").stdout.split()
    if remote not in names:
        git_safe.die("%r is not a configured remote name (%s)" % (remote, " ".join(names)))
    git_safe.check_config_origins(wt, repo, common)
    keys = g["verify"].get("on_push") or []
    if keys:
        os.environ["DT_STATE_DIR"] = state
        sys.path.insert(0, os.path.join(os.path.dirname(HERE), "hooks"))
        import dtcore
        why = dtcore.verify_record_problem(g, wt, keys, [remote, "HEAD:refs/heads/" + branch])
        if why:
            git_safe.die("%s - push refused. Run `%s %s --guard %s` from a clean, committed worktree first"
                         % (why, os.path.join(HERE, "verify-record.sh"), tid, os.path.join(state, "guard.json")))
    return git_safe.run_git(wt, "push", "--", remote, "HEAD:refs/heads/" + branch)


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
    import fixed_env      # C11e3: fixed PATH / HOME, only the kept variables, before anything runs
    fixed_env.apply()
    sys.exit(main(sys.argv[1:]))
