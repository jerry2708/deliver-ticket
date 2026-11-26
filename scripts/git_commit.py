#!/usr/bin/env python3
"""scripts/git-commit.sh --session <id> -m <message> | -F <message file>   (run from the ticket's worktree directory)

The only way Claude commits when the project sandbox is on (C11): the sandbox denies writes to the git ref store (<common dir>/refs/**, packed-refs,
logs/refs/**), so a sandboxed `git commit` cannot move a branch. This gate is excluded from the sandbox and behind a permission ask rule on its full
path (the prompt is the user's yes); the prompt shows only the command, so stage 7 shows `git diff --cached --stat=10000 --no-renames` in the call
right before it.

Refused unless: the ticket is open and its plan approved (the plan lock); HEAD is a symbolic ref to the ticket's branch as recorded in delivery.log (not
the ticket file: Claude can edit it; not just "the branch checked out here": .git/worktrees/<n>/HEAD is writable from the sandbox); that branch is not a
default / base branch; no risky git config key comes from a file Claude can edit; something is staged; the arguments are exactly `--session <id>` and
one of `-m <message>` / `-F <regular file outside the git dir>` - no --amend, -a, pathspecs or other options. git runs with the repo's hooks off
(`core.hooksPath=/dev/null`, like git-push.sh): the team's pre-commit hooks do not run on Claude's commits.
Logged to delivery.log (C11e2), read back from the commit itself: `<sha> branch=<b> tree=<commit tree> files=<JSON list>` (`diff-tree --root -r
--no-renames`: a rename is a delete + an add, as in the stat stage 7 shows; "|" escaped as \\u007c). Stage 8 lock-trace compares the list with the
`git diff --cached --stat=10000 --no-renames` output of the call right before this one. When the commit's tree differs from the staged tree, or its
parent from HEAD before the commit (the index or the branch changed during the commit), the line carries `MISMATCH staged_tree=<t> head_before=<h>`
before `files=`, a message goes to stderr and the exit code is 3: the commit exists, stage 7 stops for the user. Standard library only.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import git_safe  # noqa: E402
import plan_lock  # noqa: E402
import ticket_ctl  # noqa: E402

USAGE = "usage: git-commit.sh --session <id> -m <message> | -F <message file>"


def parse(argv):
    if len(argv) != 4:
        git_safe.die("%s (exactly these four arguments; no --amend, -a, pathspecs or other options)" % USAGE)
    opts = dict(zip(argv[0::2], argv[1::2]))
    if set(opts) not in ({"--session", "-m"}, {"--session", "-F"}):
        git_safe.die("%s (got %s)" % (USAGE, " ".join(argv[0::2])))
    sid = opts["--session"]
    if not ticket_ctl.SID_RE.fullmatch(sid):
        git_safe.die("session id %r is not a plain id" % sid)
    return sid, ("-m", opts["-m"]) if "-m" in opts else ("-F", opts["-F"])


def main(argv):
    git_safe.scrub_env()
    sid, (flag, val) = parse(argv)
    repo, state, g, wt, tid, common = git_safe.ticket_context(os.getcwd())
    if os.path.lexists(os.path.join(state, "closed", tid)):
        git_safe.die("ticket %s is closed" % tid)
    try:
        txt = open(os.path.join(state, "tickets", tid + ".md")).read()
    except OSError:
        git_safe.die("ticket file tickets/%s.md is missing" % tid)
    ok, why = plan_lock.plan_approved(state, tid, txt)
    if not ok:
        git_safe.die("the plan of %s is not approved (%s): no commit before the stage 2 gate" % (tid, why))
    rec = git_safe.recorded_branch(state, tid)
    if rec is None:
        git_safe.die("no branch is recorded for ticket %s in delivery.log (the project WorktreeCreate hook records it): commit refused" % tid)
    head = git_safe.git(wt, "symbolic-ref", "-q", "HEAD").stdout.strip()
    if head != "refs/heads/" + rec:
        git_safe.die("HEAD is %s, not the ticket's recorded branch refs/heads/%s: commit refused" % (head or "detached", rec))
    git_safe.branch_name(rec)
    git_safe.not_protected(rec, g)
    if flag == "-m":
        if not val.strip():
            git_safe.die("empty commit message")
    else:
        path = os.path.realpath(val)
        if not os.path.isfile(path) or path == common or path.startswith(common + os.sep):
            git_safe.die("message file %r is not a regular file outside the git dir" % val)
        val = path
    git_safe.check_config_origins(wt, repo, common)
    if git_safe.git(wt, "diff", "--cached", "--quiet").returncode != 1:
        git_safe.die("nothing is staged (git add the files of this commit first)")
    head_before = git_safe.git(wt, "rev-parse", "-q", "--verify", "HEAD^{commit}").stdout.strip()
    staged_tree = git_safe.git(wt, "write-tree").stdout.strip()
    rc = git_safe.run_git(wt, "commit", flag, val)
    if rc != 0:
        return rc
    # what was committed, read back from the commit (not the index before it): the index can change between write-tree and the commit
    sha = git_safe.git(wt, "rev-parse", "HEAD").stdout.strip()
    tree = git_safe.git(wt, "rev-parse", sha + "^{tree}").stdout.strip()
    parent = git_safe.git(wt, "rev-parse", "-q", "--verify", sha + "^1").stdout.strip()
    files = git_safe.git(wt, "diff-tree", "--root", "-r", "--no-commit-id", "--no-renames", "--name-only", "-z", sha).stdout.split("\0")[:-1]
    odd = ""
    if tree != staged_tree or parent != head_before:
        odd = "MISMATCH staged_tree=%s head_before=%s " % (staged_tree, head_before or "none")
    ticket_ctl.log(state, sid, tid, "commit", "%s branch=%s tree=%s %sfiles=%s" % (sha, rec, tree, odd, log_files(files)))
    if odd:
        print("git-commit: commit %s is not what was staged: its tree %s / parent %s, staged tree %s / HEAD before %s (the index or the branch changed "
              "during the commit). Logged as MISMATCH in delivery.log. STOP: show the user `git show --stat --no-renames %s` and wait for them."
              % (sha[:12], tree[:12], (parent or "none")[:12], staged_tree[:12], (head_before or "none")[:12], sha[:12]), file=sys.stderr)
        return 3
    return 0


def log_files(files):
    """The file list as one-line JSON that survives ticket_ctl.log unchanged: ASCII only (control characters become \\u escapes) and "|" (the log's
    field separator, which log() would turn into "/") as \\u007c. json.loads gives the exact names back."""
    return json.dumps(files, ensure_ascii=True).replace("|", "\\u007c")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
