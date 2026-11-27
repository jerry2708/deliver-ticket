"""The fixed environment of the scripts excluded from the sandbox (install_hooks.GATES + BOOKKEEPING) - C11e3. Standard library only.

They run unsandboxed, so nothing they start may come from a place Claude can write or from a variable Claude could set. Their .sh wrapper
(`#!/bin/bash -p`: no BASH_ENV, no imported functions) sources fixed-env.sh, which picks python3 from PY_CANDIDATES (never PATH) and starts it under
`env -i` with only the KEEP variables. apply(), called by each module's __main__, then sets PATH from fixed_path() and HOME / USER / LOGNAME from the
password database, and drops anything not in KEEP (also when a module is started some other way).

Why each kept variable: SSH_AUTH_SOCK - git-push.sh over ssh needs the user's agent; LANG, LC_* - git's messages, the locale of file names and commit
messages, as before. DELIVER_TICKET_HOME - the state root override (tests; an open item, docs/plan.md C11e3). TERM is not kept: git's output here is
captured or goes to a pipe, never a terminal. Dropped on purpose (examples): DEVELOPER_DIR (/usr/bin/git and /usr/bin/python3 are xcrun shims that run
$DEVELOPER_DIR/usr/bin/xcrun), XDG_CONFIG_HOME (git reads $XDG_CONFIG_HOME/git/config), DYLD_* (Homebrew's python3 is not SIP-protected), GIT_*, PYTHON*.

The candidates are fixed in code, in the order this machine's shell finds them today; `install-hooks.sh status` prints the choice. Any other dir
(a project's node_modules/.bin, ~/.local/bin) is never on the PATH of these scripts.
"""
import os
import pwd

PY_CANDIDATES = ("/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3")      # = fixed-env.sh (a test keeps the two equal)
GIT_CANDIDATES = ("/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git")
SYSTEM_PATH = ("/usr/bin", "/bin", "/usr/sbin", "/sbin")
KEEP = ("SSH_AUTH_SOCK", "LANG", "DELIVER_TICKET_HOME")                                              # + every LC_* (fixed-env.sh passes the same)


def first(cands):
    return next((p for p in cands if os.access(p, os.X_OK) and os.path.isfile(p)), None)


def fixed_path():
    """dir of the chosen git, dir of the chosen python3, then the system dirs; nothing from the environment."""
    out = []
    for p in (first(GIT_CANDIDATES), first(PY_CANDIDATES)):
        if p and os.path.dirname(p) not in out:
            out.append(os.path.dirname(p))
    out += [d for d in SYSTEM_PATH if d not in out]
    return ":".join(out)


def kept(name):
    return name in KEEP or name.startswith("LC_")


def apply():
    keep = {k: v for k, v in os.environ.items() if kept(k)}
    os.environ.clear()
    os.environ.update(keep)
    pw = pwd.getpwuid(os.getuid())
    os.environ.update(PATH=fixed_path(), HOME=pw.pw_dir, USER=pw.pw_name, LOGNAME=pw.pw_name)


def describe():
    return "python3 %s, git %s, PATH %s (fixed candidates, scripts/fixed_env.py)" % (first(PY_CANDIDATES) or "NONE", first(GIT_CANDIDATES) or "NONE", fixed_path())
