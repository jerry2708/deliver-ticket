#!/usr/bin/env python3
"""Shared by git-push.sh and git-rename.sh (plan.md, milestone 1c, section 1b).

Both run UNSANDBOXED (excluded from the sandbox) with arguments Claude chose, and they run git with `-c core.hooksPath=/dev/null` so that the repo's own
hooks (code from the worktree) never run unsandboxed. Hence everything is validated here, not only in the hooks. Standard library only.
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import ticket_ctl  # noqa: E402

PROTECTED = {"main", "master", "develop", "trunk"}
BAD_REF_CHARS = re.compile(r"[\s:+*?\[\]^~\\]|@\{|\.\.|//")
# git config keys that make push / rename run a program, redirect the remote or change which hooks / credentials apply
RISKY_KEYS = (r"^(core\.(sshcommand|hookspath|gitproxy|askpass|fsmonitor)|remote\..*\.(receivepack|uploadpack|pushurl|url|proxy)|"
              r"url\..*\.(insteadof|pushinsteadof)|credential\..*|include\..*|includeif\..*|gpg\..*program|push\.gpgsign)$")


def die(msg, rc=2):
    print("git-safe: %s" % msg, file=sys.stderr)
    sys.exit(rc)


def scrub_env():
    """Drop every GIT_* variable (GIT_SSH*, GIT_EXEC_PATH, GIT_CONFIG_*, GIT_DIR, GIT_WORK_TREE, GIT_ALTERNATE_OBJECT_DIRECTORIES, ...) and the askpass ones."""
    for k in list(os.environ):
        if k.startswith("GIT_") or k in ("SSH_ASKPASS", "SSH_ASKPASS_REQUIRE"):
            del os.environ[k]


def git(cwd, *a):
    return subprocess.run(["git", "-C", cwd] + list(a), capture_output=True, text=True, timeout=60)


def positional(args, n):
    if len(args) != n:
        die("expected exactly %d argument(s), got %d" % (n, len(args)))
    for a in args:
        if a.startswith("-") or not a:
            die("argument %r is not a plain name (no options: `--receive-pack=<cmd>` style arguments run programs)" % a)


def ticket_context(cwd):
    """(main checkout, state dir, guard dict, worktree toplevel, ticket id, git common dir); dies unless cwd is inside <repo>/.claude/worktrees/<ID>."""
    r = git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel")
    if r.returncode != 0:
        die("not inside a git repository: %s" % cwd)
    common, top = r.stdout.split("\n")[:2]
    repo = os.path.realpath(common[:-5] if common.endswith("/.git") else common)
    home, state, key = ticket_ctl.state_dir(repo)
    try:
        g = json.load(open(os.path.join(state, "guard.json")))
        assert g["version"] == 1 and isinstance(g["remotes"]["allowed"], list) and isinstance(g["remotes"]["forbidden"], list)
        assert isinstance(g["verify"], dict)
    except (OSError, ValueError, KeyError, AssertionError):
        die("no usable guard.json for this repo (%s)" % os.path.join(state, "guard.json"))
    base = os.path.realpath(os.path.join(g["repo_root"], ".claude", "worktrees"))
    top = os.path.realpath(top)
    if os.path.dirname(top) != base:
        die("run this from the ticket's worktree directory (%s/<ID>), not from %s" % (base, cwd))
    return repo, state, g, top, os.path.basename(top), os.path.realpath(common)


def branch_name(name, what="branch"):
    if not name or name.startswith("-") or name.startswith("/") or BAD_REF_CHARS.search(name) or name.endswith("/") or name.endswith(".lock"):
        die("%s %r is not a plain branch name" % (what, name))
    r = subprocess.run(["git", "check-ref-format", "--branch", name], capture_output=True, text=True)
    if r.returncode != 0 or r.stdout.strip() != name:
        die("%s %r is not a valid branch name" % (what, name))
    return name


def not_protected(name, g):
    if name in PROTECTED or name == g.get("base_branch"):
        die("branch %r is a default / base branch: never pushed or renamed by this skill" % name)


def check_config_origins(wt, repo, common):
    """Refuse when a risky key is set by a file inside the repository or a worktree (all worktrees live under <repo>/.claude/worktrees), the files Claude
    can edit, unless it is under the git common dir (.git/config, .git/worktrees/*/config.worktree: the sandbox keeps Claude out of those). System and
    user config files (/etc, $HOME, the Xcode / Homebrew gitconfig that sets credential.helper) are outside the repository and fine. Any origin that is not
    a file (command line, blob, standard input) is refused."""
    r = git(wt, "config", "--show-origin", "--get-regexp", RISKY_KEYS)
    if r.returncode not in (0, 1):
        die("cannot read git config (%s)" % r.stderr.strip()[:200])
    repo, common = os.path.realpath(repo), os.path.realpath(common)
    for line in r.stdout.splitlines():
        origin, _, rest = line.partition("\t")
        key = rest.split(" ")[0]
        if not origin.startswith("file:"):
            die("git config %s comes from %s, not from a config file: refused" % (key, origin))
        path = os.path.realpath(origin[5:] if os.path.isabs(origin[5:]) else os.path.join(wt, origin[5:]))
        inside = path == repo or path.startswith(repo + os.sep)
        in_git = path == common or path.startswith(common + os.sep)
        if inside and not in_git:
            die("git config %s is set in %s, a file inside the repository or a worktree (Claude can edit it): refused" % (key, path))


def run_git(wt, *a):
    """git with the repo's hooks switched off by our own -c (the repo's hook code never runs unsandboxed) and the ext transport off."""
    cmd = ["git", "-C", wt, "-c", "core.hooksPath=/dev/null", "-c", "protocol.ext.allow=never"] + list(a)
    return subprocess.run(cmd).returncode
