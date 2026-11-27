#!/usr/bin/env python3
"""env-keys.sh <env file> --repo <main checkout> - the KEY NAMES of an env file, never a value. The only sanctioned way for the skill to learn what an env file holds.

C11h: a BOOKKEEPING script (excluded from the sandbox, allow rule, no prompt; install_hooks.BOOKKEEPING). The project sandbox denies reading `<repo>/**/.env*`
(and the user-level `Read(**/.env*)` rule is also a sandbox deny, anchored at the session's cwd), so a sandboxed run could not read the file; unsandboxed, this
script is the boundary and validates strictly.

C11h h: the repository is taken from the delivery state, never from `.git` entries on disk (Claude can write a fake `.git` file into a worktree subdirectory -
the sandbox allows writes there - and point it anywhere). `--repo` names the main checkout; its project key (`<basename>-<first 8 hex of sha1 of the path>`,
hooks/lib.sh dt_key) selects `<state root>/<key>/guard.json` (protected state, written only through guard-apply.sh), whose `repo_root` must be that same
directory. The state root is DELIVER_TICKET_HOME or ~/.local/share/deliver-ticket (the fixed environment of the excluded scripts keeps only that variable;
probe C11e3: Claude cannot set it for an excluded command). No git command runs. Then:
  - the given path's basename and its realpath's basename both start with `.env` (case-insensitive: macOS folds case);
  - the realpath is a regular file under repo_root, with no `.git` path component below repo_root (ticket worktrees live in <repo_root>/.claude/worktrees/
    and their env links point into the main checkout);
  - it prints only names matching `[export ]NAME=`; a value never leaves this process. Max 1 MB.
A project with no guard.json (init before step 2) is refused: the key names stay unknown until the project state exists.
Exit 0 names printed (possibly none), 1 no such file, 2 refused / usage.
"""
import hashlib
import json
import os
import re
import sys

NAME = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=")
MAX_BYTES = 1024 * 1024


def refuse(msg, rc=2):
    print("env-keys.sh: %s" % msg, file=sys.stderr)
    return rc


def is_env_base(p):
    return os.path.basename(p).lower().startswith(".env")


def under(p, root):
    return p == root or p.startswith(root.rstrip(os.sep) + os.sep)


def state_root():
    return os.path.realpath(os.environ.get("DELIVER_TICKET_HOME") or os.path.expanduser("~/.local/share/deliver-ticket"))


def project_key(repo):
    return "%s-%s" % (os.path.basename(repo), hashlib.sha1(repo.encode()).hexdigest()[:8])


def parse(argv):
    """(file, repo) or None: exactly `<file> --repo <dir>` in either order, no other option."""
    if len(argv) != 3:
        return None
    if argv[0] == "--repo":
        repo, rest = argv[1], argv[2]
    elif argv[1] == "--repo":
        rest, repo = argv[0], argv[2]
    else:
        return None
    if not rest or rest.startswith("-") or not repo or repo.startswith("-"):
        return None
    return rest, repo


def main(argv):
    pa = parse(argv)
    if not pa:
        return refuse("usage: env-keys.sh <env file> --repo <main checkout>")
    given, repo_arg = pa
    if not is_env_base(given):
        return refuse("only .env* files (got %s)" % os.path.basename(given))
    repo = os.path.realpath(repo_arg)
    gpath = os.path.join(state_root(), project_key(repo), "guard.json")
    try:
        with open(gpath) as f:
            root = os.path.realpath(json.load(f)["repo_root"])
    except (OSError, ValueError, KeyError, TypeError):
        return refuse("no usable delivery state for %s (%s) - project not initialised, or --repo is not its main checkout; key names stay unknown" % (repo_arg, gpath))
    if root != repo:
        return refuse("--repo %s is not the repo_root of its own guard.json (%s) - refused" % (repo, root))
    path = os.path.join(os.path.realpath(os.getcwd()), given)
    if not os.path.lexists(path):
        return refuse("no such file: %s" % given, 1)
    rp = os.path.realpath(path)
    if not is_env_base(rp):
        return refuse("%s resolves to %s, which is not a .env* file - refused" % (given, rp))
    if not under(rp, root) or rp == root:
        return refuse("%s resolves to %s, outside the repo %s - refused" % (given, rp, root))
    if ".git" in [c.lower() for c in os.path.relpath(rp, root).split(os.sep)]:
        return refuse("%s resolves to %s, inside a .git directory - refused" % (given, rp))
    if not os.path.isfile(rp):
        return refuse("%s is not a regular file" % given, 1)
    if os.path.getsize(rp) > MAX_BYTES:
        return refuse("%s is larger than 1 MB - refused" % given)
    with open(rp, "rb") as f:
        text = f.read().decode("utf-8", "replace")
    for line in text.splitlines():
        m = NAME.match(line)
        if m:
            print(m.group(1))
    return 0


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
    import fixed_env
    fixed_env.apply()
    sys.exit(main(sys.argv[1:]))
