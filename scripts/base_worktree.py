#!/usr/bin/env python3
"""scripts/base-worktree.sh acquire <ticket-id> <commit-ish> --repo <repo-root>   # prints the worktree path; exit 3 = tracked changes in it, 4 = held by another ticket
   scripts/base-worktree.sh release <ticket-id> --repo <repo-root>

The shared, detached BASE worktree used to re-run a failing check on the base (stage 4 triage). Never the main checkout: build / lint there would write
.next / dist / .turbo and can break a running dev server. Path: <repo>/.claude/worktrees/_base (same root as the ticket worktrees, excluded by init). Created
once (`git worktree add --detach`), then moved to the ticket's base commit with `checkout --detach`. One ticket holds it at a time (lock in the git common
dir). It is never removed here: removal needs the user's OK.

C11c3: a BOOKKEEPING script (excluded from the sandbox, allow rule, no prompt): the checkout writes `_base/.claude/settings*.json` when the repo tracks them,
which the project sandbox denies (DRY-01). So it runs unsandboxed with arguments Claude chose, and validates them here (git_safe: scrubbed env, config-origin
check, repo hooks off - `post-checkout` would otherwise run worktree code unsandboxed):
  - <ticket-id> a plain ID and, for acquire, an open ticket of this project (tickets/<ID>.md, no closed/<ID>; the ticket file is Claude-writable, so this
    ties the call to a ticket ID, it is not a trust boundary); --repo the main checkout of a repo with delivery state, equal to guard.json `repo_root`;
  - <commit-ish> no leading `-`, a commit, and an ancestor of refs/heads/<guard.json base_branch> (`git merge-base --is-ancestor`): only base-branch code is
    checked out here, never a ticket commit;
  - _base, when it exists, is that repo's registered worktree at exactly that path (not a symlink), and its `.git` gitfile (sandbox-writable) still points to
    <common>/worktrees/<n>, whose `gitdir` points back to _base: a repointed gitfile would make git read a config / index Claude wrote.
A symlink planted in _base where the target commit has a tracked directory: git refuses the checkout ("untracked working tree files would be overwritten"),
the lock is released, nothing is written through it (tests/run-base-worktree.sh, probe base_worktree_symlinked_dir).
It does NOT install dependencies or link env files: that is `setup-worktree.sh <repo> <_base> _base`, a separate call INSIDE the sandbox (_base is
sandbox-writable, so an install run from here would run files Claude could have planted there - .npmrc, .pnpmfile.cjs, node_modules - unsandboxed).
"""
import errno
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import git_safe  # noqa: E402
import ticket_ctl  # noqa: E402

USAGE = "usage: base-worktree.sh acquire <ticket-id> <commit-ish> --repo <repo-root> | release <ticket-id> --repo <repo-root>"


def parse(argv):
    if len(argv) < 2 or argv[0] not in ("acquire", "release"):
        git_safe.die(USAGE)
    cmd, tid, rest = argv[0], argv[1], argv[2:]
    commit = None
    if cmd == "acquire":
        if not rest or rest[0].startswith("-"):
            git_safe.die("acquire needs a commit (no leading '-'): " + USAGE)
        commit, rest = rest[0], rest[1:]
    if len(rest) != 2 or rest[0] != "--repo" or not rest[1]:
        git_safe.die(USAGE)
    if not ticket_ctl.TOKEN_RE.fullmatch(tid):
        git_safe.die("ticket id %r is not a plain ID" % tid)
    return cmd, tid, commit, rest[1]


def repo_context(arg):
    """(main checkout realpath, git common dir, guard dict); dies unless `arg` is the main checkout of a repo whose guard.json names it."""
    r = git_safe.git(arg, "rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel")
    if r.returncode != 0:
        git_safe.die("--repo %s is not a git repository" % arg)
    common, top = (os.path.realpath(x) for x in r.stdout.split("\n")[:2])
    repo = os.path.realpath(arg)
    if common != os.path.join(repo, ".git") or top != repo or not os.path.isdir(common):
        git_safe.die("--repo %s is not the main checkout of its repository (git dir %s, top level %s)" % (arg, common, top))
    _, state, _ = ticket_ctl.state_dir(repo)
    try:
        g = json.load(open(os.path.join(state, "guard.json")))
        base = g["base_branch"]
        root = os.path.realpath(g["repo_root"])
    except (OSError, ValueError, KeyError, TypeError):
        git_safe.die("no usable guard.json for %s (%s)" % (repo, os.path.join(state, "guard.json")))
    if root != repo:
        git_safe.die("--repo %s is not guard.json repo_root (%s)" % (repo, root))
    git_safe.branch_name(base, "guard.json base_branch")
    return repo, common, g, state


def open_ticket(state, tid):
    t = os.path.join(state, "tickets", tid + ".md")
    if not os.path.isfile(t) or os.path.islink(t):
        git_safe.die("%s is not a ticket of this project (no tickets/%s.md)" % (tid, tid))
    if os.path.lexists(os.path.join(state, "closed", tid)):
        git_safe.die("ticket %s is closed" % tid)


def base_commit(repo, commit, base):
    r = git_safe.git(repo, "rev-parse", "--verify", "-q", "--end-of-options", commit + "^{commit}")
    sha = r.stdout.strip()
    if r.returncode != 0 or not sha:
        git_safe.die("%r is not a commit in %s" % (commit, repo))
    ref = "refs/heads/" + base
    if git_safe.git(repo, "rev-parse", "--verify", "-q", ref).returncode != 0:
        git_safe.die("base branch %s does not exist in %s" % (ref, repo))
    r = git_safe.git(repo, "merge-base", "--is-ancestor", sha, ref)
    if r.returncode == 1:
        git_safe.die("%s (%s) is not on the base branch %s: only base-branch commits go into _base (use `git merge-base HEAD %s`)" % (commit, sha[:12], base, base))
    if r.returncode != 0:
        git_safe.die("git merge-base --is-ancestor failed: %s" % r.stderr.strip()[:200])
    return sha


def check_base_path(repo, common, w):
    """_base, if it exists: a real directory (no symlink, no symlinked parent), registered as a worktree of this repo."""
    if os.path.realpath(w) != w:
        git_safe.die("%s resolves to %s (a symlink in the path): refused" % (w, os.path.realpath(w)))
    if not os.path.lexists(w):
        return False
    if not os.path.isdir(w):
        git_safe.die("%s exists and is not a directory: tell the user" % w)
    listed = [l[len("worktree "):] for l in git_safe.git(repo, "worktree", "list", "--porcelain").stdout.splitlines() if l.startswith("worktree ")]
    r = git_safe.git(w, "rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel")
    parts = r.stdout.split("\n")[:2] if r.returncode == 0 else ["", ""]
    if w not in [os.path.realpath(x) for x in listed] or os.path.realpath(parts[0]) != common or os.path.realpath(parts[1]) != w:
        git_safe.die("%s exists but is not a registered worktree of %s: not touching it - tell the user" % (w, repo))
    gd = os.path.realpath(git_safe.git(w, "rev-parse", "--absolute-git-dir").stdout.strip() or "/nonexistent")
    try:
        back = os.path.realpath(open(os.path.join(gd, "gitdir")).read().strip())
    except OSError:
        back = None
    if os.path.dirname(gd) != os.path.join(common, "worktrees") or back != os.path.join(w, ".git"):
        git_safe.die("%s/.git does not point to its own entry under %s/worktrees (points to %s): not touching it - tell the user" % (w, common, gd))
    return True


def take_lock(lock, tid):
    try:
        os.mkdir(lock)
    except FileExistsError:
        try:
            holder = open(os.path.join(lock, "ticket")).read().strip() or "?"
        except OSError:
            holder = "?"
        if holder != tid:
            print("base-worktree: held by ticket %s; release it first (lock: %s)" % (holder, lock), file=sys.stderr)
            sys.exit(4)
        return
    except OSError as e:
        git_safe.die("cannot create the lock %s: %s" % (lock, os.strerror(e.errno or errno.EIO)), 1)
    open(os.path.join(lock, "ticket"), "w").write(tid + "\n")


def drop_lock(lock):
    os.remove(os.path.join(lock, "ticket"))
    os.rmdir(lock)


def main(argv):
    git_safe.scrub_env()
    cmd, tid, commit, repo_arg = parse(argv)
    repo, common, g, state = repo_context(repo_arg)
    lock = os.path.join(common, "deliver-ticket-base.lock")
    w = os.path.join(repo, ".claude", "worktrees", "_base")
    if cmd == "release":
        try:
            holder = open(os.path.join(lock, "ticket")).read().strip()
        except OSError:
            holder = ""
        if holder != tid:
            print("base-worktree: not held by %s (holder: %s)" % (tid, holder or "none"), file=sys.stderr)
            return 4
        drop_lock(lock)
        print("released")
        return 0
    open_ticket(state, tid)
    sha = base_commit(repo, commit, g["base_branch"])
    exists = check_base_path(repo, common, w)
    git_safe.check_config_origins(w if exists else repo, repo, common)
    take_lock(lock, tid)
    if not exists:
        rc = git_safe.run_git(repo, "worktree", "add", "-q", "--detach", w, sha, stdout=sys.stderr)
        if rc != 0:
            drop_lock(lock)
            return 1
    else:
        st = git_safe.git(w, "status", "--porcelain", "--untracked-files=no")
        if st.returncode != 0 or st.stdout.strip():
            print("base-worktree: %s has tracked changes (or git status failed); not touching it - tell the user" % w, file=sys.stderr)
            drop_lock(lock)
            return 3
        rc = git_safe.run_git(w, "checkout", "-q", "--detach", sha, stdout=sys.stderr)
        if rc != 0:
            print("base-worktree: git checkout in %s failed (message above); lock released, _base left as it is - tell the user" % w, file=sys.stderr)
            drop_lock(lock)
            return 1
    print(w)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
