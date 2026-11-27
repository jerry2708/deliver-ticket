#!/usr/bin/env python3
"""env-keys.sh <env file> - the KEY NAMES of an env file, never a value. The only sanctioned way for the skill to learn what an env file holds.

C11h: a BOOKKEEPING script (excluded from the sandbox, allow rule, no prompt; install_hooks.BOOKKEEPING). The project sandbox denies reading `<repo>/**/.env*`
(and the user-level `Read(**/.env*)` rule is also a sandbox deny, anchored at the session's cwd), so a sandboxed run could not read the file; unsandboxed, this
script is the boundary and validates strictly:
  - the given path's basename and its realpath's basename both start with `.env` (case-insensitive: macOS folds case);
  - the realpath is a regular file under the main checkout of the git repository of the current directory (ticket worktrees live in
    <main>/.claude/worktrees/ and their env links point into the main checkout), not under its .git directory;
  - the main checkout is found from the .git entries on disk (no git command: git would read repo config unsandboxed);
  - it prints only names matching `[export ]NAME=`; a value never leaves this process. Max 1 MB.
Exit 0 names printed (possibly none), 1 no such file, 2 refused / usage.
"""
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


def main_checkout(start):
    """The main checkout (the directory holding the common .git dir) of the repository containing `start`, or None."""
    d = start
    while True:
        g = os.path.join(d, ".git")
        if os.path.isdir(g) and not os.path.islink(g):
            return d
        if os.path.isfile(g) and not os.path.islink(g):
            try:
                txt = open(g).read(4096).strip()
            except OSError:
                return None
            if not txt.startswith("gitdir:"):
                return None
            gitdir = os.path.realpath(os.path.join(d, txt[len("gitdir:"):].strip()))
            try:
                common = open(os.path.join(gitdir, "commondir")).read(4096).strip()
            except OSError:
                return None
            common = os.path.realpath(os.path.join(gitdir, common))
            return os.path.dirname(common) if os.path.basename(common) == ".git" else None
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def main(argv):
    if len(argv) != 1 or not argv[0] or argv[0].startswith("-"):
        return refuse("usage: env-keys.sh <env file>")
    given = argv[0]
    if not is_env_base(given):
        return refuse("only .env* files (got %s)" % os.path.basename(given))
    cwd = os.path.realpath(os.getcwd())
    path = os.path.join(cwd, given)
    if not os.path.lexists(path):
        return refuse("no such file: %s" % given, 1)
    rp = os.path.realpath(path)
    if not is_env_base(rp):
        return refuse("%s resolves to %s, which is not a .env* file - refused" % (given, rp))
    main_dir = main_checkout(cwd)
    if not main_dir:
        return refuse("the current directory %s is not in a git repository with a main checkout - refused" % cwd)
    if not under(rp, main_dir) or under(rp, os.path.join(main_dir, ".git")):
        return refuse("%s resolves to %s, outside the main checkout %s - refused" % (given, rp, main_dir))
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
