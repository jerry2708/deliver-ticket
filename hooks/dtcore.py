#!/usr/bin/env python3
"""Core of the deliver-ticket hooks. Called by hooks/*.sh through lib.sh `dt_core <mode>`,
only when the repo has delivery state (guard.json exists). Payload JSON on stdin.

Modes: guard (PreToolUse Bash), verify (PreToolUse Bash, git push), wguard (PreToolUse
Edit/Write/NotebookEdit + PostToolUse EnterWorktree), session (SessionStart compact).
Exit 0 = allow, 2 = block (message on stderr). Fail-closed: anything it cannot parse blocks.
Standard library only. Known limit: it reads the shell command text; code run by an
interpreter (python script.py, make, npm run) can do anything and is not analysed.
"""
import fnmatch
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys

HOME = os.path.realpath(os.path.expanduser("~"))
STATE = os.environ.get("DT_STATE_DIR", "")
NAMED = os.environ.get("DT_NAMED") == "1"      # mode nostate: the payload names the state root (else only a delete / move verb triggered it)
DT_HOME = os.path.realpath(os.environ.get("DT_HOME") or os.environ.get("DELIVER_TICKET_HOME") or os.path.join(HOME, ".local/share/deliver-ticket"))
SKILL_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
SKILL_SCRIPTS = os.path.join(SKILL_DIR, "scripts")


class Block(Exception):
    pass


def block(msg):
    raise Block(msg)


# ---------------------------------------------------------------- guard.json

def load_guard():
    """Return guard dict, or None when it exists but is unusable (caller decides)."""
    try:
        with open(os.path.join(STATE, "guard.json")) as f:
            g = json.load(f)
        assert isinstance(g, dict) and g.get("version") == 1
        assert os.path.isabs(g["repo_root"])
        r = g["remotes"]
        assert isinstance(r["allowed"], list) and isinstance(r["forbidden"], list)
        assert isinstance(g["verify"], dict)
        return g
    except Exception:
        return None


# ---------------------------------------------------------------- shell parsing

KEYWORDS = {"!", "{", "}", "do", "then", "else", "elif", "if", "while", "until", "time",
            "nohup", "exec", "command", "builtin", "sudo", "env", "nice", "xargs"}
WRAPPERS = {"time", "nohup", "exec", "command", "builtin", "sudo", "env", "nice", "xargs"}   # also when written as /usr/bin/env ...
SHELLS = {"bash", "sh", "zsh", "dash"}
ENV_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
SUBST = "\x00SUBST\x00"


class ParseError(Exception):
    pass


def _match_paren(s, i):
    """s[i] is the char after '(' ; return index of the matching ')'."""
    depth, q = 1, None
    while i < len(s):
        c = s[i]
        if q:
            if c == "\\" and q == '"':
                i += 1
            elif c == q:
                q = None
        elif c == "\\":
            i += 1
        elif c in "'\"":
            q = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ParseError("unterminated ( in command")


def tokenize(s, subs):
    """Return segments: list of lists of items; item = ('w', text) | ('r', op).
    Command substitutions are collected in `subs` (inner strings) and replaced by SUBST."""
    segs, cur, word = [], [], None
    heredocs = []  # (delimiter, quoted) waiting for the next newline
    i, n = 0, len(s)

    def endword():
        nonlocal word
        if word is not None:
            cur.append(("w", word))
            word = None

    def endseg():
        nonlocal cur
        endword()
        if cur:
            segs.append(cur)
        cur = []

    def add(t):
        nonlocal word
        word = (word or "") + t

    while i < n:
        c = s[i]
        if c == "\\":
            if i + 1 >= n:
                raise ParseError("trailing backslash")
            if s[i + 1] == "\n":
                i += 2
                continue
            add(s[i + 1])
            i += 2
        elif c == "'":
            j = s.find("'", i + 1)
            if j < 0:
                raise ParseError("unterminated '")
            add(s[i + 1:j])
            word = word or ""
            i = j + 1
        elif c == '"':
            word = word or ""
            i += 1
            while True:
                if i >= n:
                    raise ParseError('unterminated "')
                d = s[i]
                if d == '"':
                    i += 1
                    break
                if d == "\\" and i + 1 < n and s[i + 1] in '$"\\`\n':
                    if s[i + 1] != "\n":
                        add(s[i + 1])
                    i += 2
                elif d == "$" and s.startswith("$(", i):
                    j = _match_paren(s, i + 2)
                    subs.append(s[i + 2:j])
                    add(SUBST)
                    i = j + 1
                elif d == "`":
                    j = s.find("`", i + 1)
                    if j < 0:
                        raise ParseError("unterminated `")
                    subs.append(s[i + 1:j])
                    add(SUBST)
                    i = j + 1
                else:
                    add(d)
                    i += 1
        elif c == "$" and s.startswith("$(", i):
            j = _match_paren(s, i + 2)
            subs.append(s[i + 2:j])
            add(SUBST)
            i = j + 1
        elif c == "`":
            j = s.find("`", i + 1)
            if j < 0:
                raise ParseError("unterminated `")
            subs.append(s[i + 1:j])
            add(SUBST)
            i = j + 1
        elif c == "#" and word is None:
            while i < n and s[i] != "\n":
                i += 1
        elif c in " \t":
            endword()
            i += 1
        elif c == "\n":
            endseg()
            i += 1
            for delim, quoted in heredocs:
                m = re.search(r"^[ \t]*" + re.escape(delim) + r"[ \t]*$", s[i:], re.M)
                if not m:
                    raise ParseError("unterminated heredoc")
                if not quoted:  # unquoted body expands $(...) and backticks
                    body = s[i:i + m.start()]
                    for mm in re.finditer(r"\$\(", body):
                        subs.append(body[mm.end():_match_paren(body, mm.end())])
                    for mm in re.finditer(r"`([^`]*)`", body):
                        subs.append(mm.group(1))
                i += m.end()
            heredocs = []
        elif c in ";(){}" and not (c in "{}" and word is not None):
            if c in "{}":
                endword()
                word = c
                endword()
            else:
                endseg()
            i += 1
        elif c == "&":
            if s.startswith("&>>", i):
                endword(); cur.append(("r", "&>>")); i += 3
            elif s.startswith("&>", i):
                endword(); cur.append(("r", "&>")); i += 2
            else:
                endseg()
                i += 2 if s.startswith("&&", i) else 1
        elif c == "|":
            if s.startswith(">|", i):
                pass
            endseg()
            i += 2 if s[i:i + 2] in ("||", "|&") else 1
        elif c in "<>":
            if s.startswith("<(", i) or s.startswith(">(", i):
                j = _match_paren(s, i + 2)
                subs.append(s[i + 2:j])
                add(SUBST)
                i = j + 1
                continue
            # a pure-digit word right before the operator is the fd number, not an argument
            if word is not None and word.isdigit():
                word = None
            else:
                endword()
            m = re.match(r"<<<|<<-?|>>|>\||>&|<&|<>|>|<", s[i:])
            op = m.group(0)
            i += len(op)
            if op in ("<<", "<<-"):
                j = i
                while j < n and s[j] in " \t":
                    j += 1
                k = j
                while k < n and s[k] not in " \t\n;|&<>()":
                    k += 1
                raw = s[j:k]
                delim = raw.replace("'", "").replace('"', "").replace("\\", "")
                if not delim:
                    raise ParseError("heredoc without delimiter")
                heredocs.append((delim, raw != delim))
                i = k
            else:
                cur.append(("r", op))
        else:
            add(c)
            i += 1
    if heredocs:
        raise ParseError("heredoc without body")
    endseg()
    return segs


def resolve_vars(p):
    for name, val in (("TMPDIR", os.environ.get("TMPDIR", "/tmp")), ("HOME", HOME),
                      ("PWD", os.getcwd())):
        p = p.replace("${%s}" % name, val).replace("$%s" % name, val)
    return p


def pname(word):
    """Program name for every rule: basename, lower case. Command names are case-insensitive on a case-insensitive filesystem
    (`GIT --version` runs git, `RM -rf` runs rm - probed on macOS APFS), and a rule that compared the spelling would miss them."""
    return os.path.basename(word).lower()


class Cmd:
    def __init__(self, argv, redirs, cwd, assigns, prefix=(), nested=False):
        self.argv, self.redirs, self.cwd, self.assigns = argv, redirs, cwd, assigns
        self.prefix = list(prefix)      # wrapper words stripped in front of argv[0] (env, command, xargs, /usr/bin/env ...)
        self.nested = nested            # found inside bash -c, eval or $( ): the harness sees the outer text, not this command


def analyze(text, cwd, depth=0):
    """Return list of Cmd for a shell command string. Raises ParseError."""
    if depth > 6:
        raise ParseError("command nesting too deep")
    subs = []
    segs = tokenize(text, subs)
    out = []
    for inner in subs:
        out += analyze(inner, cwd, depth + 1)
    for seg in segs:
        argv, redirs, assigns, prefix = [], [], [], []
        k = 0
        while k < len(seg):
            kind, v = seg[k]
            if kind == "r":
                k += 1
                if k < len(seg) and seg[k][0] == "w":
                    if v not in (">&", "<&", "<<<"):
                        redirs.append((v, seg[k][1]))
                    k += 1
                else:
                    raise ParseError("redirect without target")
                continue
            if not argv and ENV_RE.match(v):
                assigns.append(v)
            elif not argv and (v.lower() in KEYWORDS or ("/" in v and pname(v) in WRAPPERS)):
                prefix.append(v)
            elif not argv and v.lower() == "export":
                argv.append(v)
            else:
                argv.append(v)
            k += 1
        # `env -i FOO=bar cmd` style: drop leftover assignments/flags after a stripped prefix
        while argv and argv[0] != "export" and ENV_RE.match(argv[0]):
            assigns.append(argv.pop(0))
        if not argv and not redirs and not assigns:
            continue
        if argv and argv[0] in ("cd", "pushd"):
            tgt = argv[1] if len(argv) > 1 else HOME
            tgt = os.path.expanduser(resolve_vars(tgt))
            if SUBST in tgt or "$" in tgt or cwd is None:
                cwd = None
            else:
                cwd = os.path.realpath(os.path.join(cwd, tgt))
            out.append(Cmd(argv, redirs, cwd, assigns, prefix, depth > 0))
            continue
        c = Cmd(argv, redirs, cwd, assigns, prefix, depth > 0)
        out.append(c)
        prog = pname(argv[0]) if argv else ""
        if prog in SHELLS and "-c" in argv:
            idx = argv.index("-c")
            if idx + 1 < len(argv):
                out += analyze(argv[idx + 1], cwd, depth + 1)
        elif prog == "eval":
            out += analyze(" ".join(argv[1:]), cwd, depth + 1)
    return out


# ---------------------------------------------------------------- allowlist

_CI = {}


def fs_ci(root):
    """True when the filesystem holding `root` ignores case (detected, not assumed: macOS APFS usually does, Linux
    usually does not). On such a filesystem `<state>/k/CLOSED/t1` is the file `<state>/k/closed/T1`, and os.path.realpath
    does not fold case, so every path comparison below has to. Probe: the case-swapped name of the nearest existing
    ancestor with letters in its name is the same file."""
    if root in _CI:
        return _CI[root]
    q = root
    while q and not os.path.lexists(q):
        q = os.path.dirname(q)
    res = False
    while q and q != "/":
        base, par = os.path.basename(q), os.path.dirname(q)
        if base.swapcase() != base:
            alt = os.path.join(par, base.swapcase())
            try:
                res = os.path.lexists(alt) and os.path.samefile(alt, q)
            except OSError:
                res = False
            break
        q = par
    _CI[root] = res
    return res


def under(path, root):
    if fs_ci(root):
        path, root = path.casefold(), root.casefold()
    return path == root or path.startswith(root.rstrip("/") + "/")


def real(path):
    return os.path.realpath(path)


def first_component(path, root):
    """The first path component of `path` below `root` ("." when path is root). Only valid after under(path, root).
    Counts components instead of slicing the string, so it holds when under() matched with case folded
    (os.path.relpath would give ".." for /USERS/x against /Users/x)."""
    n = len([c for c in root.split("/") if c])
    parts = [c for c in path.split("/") if c]
    return parts[n] if len(parts) > n else "."


def allowed_roots(g, payload, cwd):
    roots = [DT_HOME]
    for t in (os.environ.get("TMPDIR"), "/tmp", "/private/tmp"):
        if t:
            roots.append(real(t))
    sp = payload.get("scratchpad_dir")
    if isinstance(sp, str) and sp.startswith("/"):
        roots.append(real(sp))
    for e in g.get("allowlist_extra") or []:
        roots.append(real(os.path.expanduser(e)))
    wt_root = real(os.path.join(g["repo_root"], ".claude", "worktrees"))
    sid = payload.get("session_id")
    if isinstance(sid, str) and re.fullmatch(r"[A-Za-z0-9._-]+", sid):
        try:
            for line in open(os.path.join(DT_HOME, "sessions", sid)):
                if line.startswith("worktree="):
                    w = real(line.split("=", 1)[1].strip())
                    if under(w, wt_root):
                        roots.append(w)
        except OSError:
            pass
    if cwd and under(real(cwd), wt_root):
        rel = first_component(real(cwd), wt_root)
        roots.append(os.path.join(wt_root, rel))
    return roots


TOKEN_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")


def _sid(payload):
    sid = payload.get("session_id")
    return sid if isinstance(sid, str) and re.fullmatch(r"[A-Za-z0-9._-]+", sid) else None


def read_map(sid):
    """sessions/<sid> -> list of (key, value); the file is written only by the bind / EnterWorktree hooks and the skill's scripts."""
    try:
        return [tuple(l.split("=", 1)) for l in open(os.path.join(DT_HOME, "sessions", sid)).read().splitlines() if "=" in l]
    except OSError:
        return []


def write_map(sid, lines):
    d = os.path.join(DT_HOME, "sessions")
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".%s.%d.tmp" % (sid, os.getpid()))
    with open(tmp, "w") as fh:
        fh.write("".join("%s=%s\n" % kv for kv in lines))
    os.replace(tmp, os.path.join(d, sid))


def ticket_closed(token):
    """done / cancelled: a marker written only by scripts/ticket-state.sh (the ticket file's `state:` text is not trusted)."""
    return os.path.exists(os.path.join(STATE, "closed", token))


def session_bound(payload, g, cwd):
    """(ticket, how) for the open ticket this session works on, or None; how = map | worktree | cwd. Bound = full guard (main checkout read-only, allowlist).
    A session with no open ticket keeps Claude Code's normal behaviour except the always-on rules."""
    wt_root = real(os.path.join(g["repo_root"], ".claude", "worktrees"))
    proj = os.path.basename(STATE)
    sid = _sid(payload)
    lines = read_map(sid) if sid else []
    cands = []                                       # (token, ticket file must exist, how it binds)
    if any(k == "project" and v == proj for k, v in lines):
        # A pause only counts while the ticket has no worktree on disk. The session can set a pause itself
        # (session-map.sh pause --after-stage8 trusts the ticket file's `stage:`, which Claude writes), so a ticket
        # with code must not be unbound by it.
        paused = {v for k, v in lines if k == "paused" and not os.path.isdir(os.path.join(wt_root, v))}
        for k, v in lines:
            if k == "ticket" and TOKEN_RE.fullmatch(v) and v not in paused:
                cands.append((v, False, "map"))
            elif k == "worktree":
                w = real(v)
                if under(w, wt_root) and first_component(w, wt_root) != ".":
                    t = first_component(w, wt_root)
                    if t not in paused:
                        cands.append((t, True, "worktree"))
    if cwd and under(real(cwd), wt_root) and first_component(real(cwd), wt_root) != ".":
        cands.append((first_component(real(cwd), wt_root), True, "cwd"))
    for t, needs_file, via in cands:
        if ticket_closed(t):
            continue
        if needs_file and not os.path.isfile(os.path.join(STATE, "tickets", t + ".md")):
            continue
        return t, via
    return None


# The protected state under the state root, relative; True = a dir (everything below it too). protected_state() is the check; install_hooks.py derives the
# user-level sandbox denyWrite and the Edit deny rules from this list (tests/run-installer.sh asserts that each entry satisfies protected_state).
PROTECTED_STATE = (("sessions", True), ("*/closed", True), ("*/guard.json", False), ("*/delivery.log", False), ("*/approvals", True), ("starts", True))


def protected_state(rp):
    """Written only by the bind hook and the skill's own scripts, in every session (guard.json: scripts/guard-write.sh)."""
    if under(rp, os.path.join(DT_HOME, "sessions")) or under(rp, os.path.join(DT_HOME, "starts")):       # starts/: the SessionStart start-dir records (hooks/session-record.sh)
        return True
    return bool(re.match(re.escape(DT_HOME) + r"/[^/]+/(closed(/|$)|approvals(/|$)|delivery\.log$|guard\.json$)", rp, re.I if fs_ci(DT_HOME) else 0))


DESTRUCTIVE = {"rm", "rmdir", "unlink", "shred", "mv"}
_GLOB = re.compile(r"[*?\[]")
STATE_WHY = ("%s the delivery state (%s) - that would disable every guard; state files change only through the skill's "
             "scripts (scripts/guard-write.sh, scripts/session-map.sh, scripts/ticket-state.sh)")


def _comps(p):
    return [c for c in p.split("/") if c]


def _cmatch(pat, name, ci):
    return fnmatch.fnmatch(name.lower(), pat.lower()) if ci else fnmatch.fnmatchcase(name, pat)


def state_reason(prog, t, cwd):
    """A reason when write target `t` of `prog` removes or moves the delivery state: the state root, any ancestor of it,
    a project state dir or sessions/ (rm, rmdir, unlink, shred, mv), or - written with a glob - could match one of those
    or a protected name (guard.json, delivery.log, closed/, sessions/). A glob component counts only if it can match the
    next component on the way to the root (`~/.local/share/*` yes, `~/.local/share/foo*` no). None when it is fine or the
    path cannot be resolved here (the callers' own rules handle that)."""
    p = resolve_vars(os.path.expanduser(t))
    if SUBST in p or "$" in p:
        return None
    if not os.path.isabs(p):
        if cwd is None:
            return None
        p = os.path.join(cwd, p)
    ci = fs_ci(DT_HOME)
    root = _comps(DT_HOME)
    n = len(root)
    destructive = prog in DESTRUCTIVE
    if not _GLOB.search(p):
        if not destructive:
            return None
        rp = real(p)
        if under(DT_HOME, rp):
            return STATE_WHY % ("%s %s" % (prog, "removes or moves"), "the state root or a parent of it")
        if under(rp, DT_HOME) and len(_comps(rp)) == n + 1 and os.path.isdir(rp):
            return STATE_WHY % ("%s %s" % (prog, "removes or moves"), "a project state dir or sessions/")
        return None
    parts = _comps(os.path.normpath(p))
    k = 0
    while k < len(parts) and not _GLOB.search(parts[k]):
        k += 1
    tc = _comps(real("/" + "/".join(parts[:k]))) + parts[k:]
    for i in range(min(len(tc), n)):
        if not _cmatch(tc[i], root[i], ci):
            return None
    try:
        kids = [d for d in os.listdir(DT_HOME) if os.path.isdir(os.path.join(DT_HOME, d))]
    except OSError:
        kids = []
    if len(tc) <= n:
        if destructive:
            return STATE_WHY % ("%s with a glob %s" % (prog, "removes or moves"), "the state root or a parent of it")
        return None
    if len(tc) == n + 1:
        if destructive and any(_cmatch(tc[n], d, ci) for d in kids):
            return STATE_WHY % ("%s with a glob %s" % (prog, "removes or moves"), "project state dirs or sessions/")
        return None
    if not any(_cmatch(tc[n], d, ci) for d in kids):
        return None
    sess = _cmatch(tc[n], "sessions", ci) or _cmatch(tc[n], "starts", ci)
    if len(tc) == n + 2 and (sess or any(_cmatch(tc[n + 1], x, ci) for x in ("guard.json", "delivery.log", "closed", "approvals"))):
        return STATE_WHY % ("a glob in the target of %s could match" % prog, "a protected file")
    if len(tc) > n + 2 and (sess or _cmatch(tc[n + 1], "closed", ci) or _cmatch(tc[n + 1], "approvals", ci)):
        return STATE_WHY % ("a glob in the target of %s could match" % prog, "a protected file")
    return None


DIR_COPY_PROGS = {"cp", "ln", "mv", "install", "rsync", "tar", "bsdtar", "gtar", "gnutar", "unzip", "ditto", "pax", "cpio", "7z", "7za", "7zr", "7zz", "7zip", "git clone", "git init", "git worktree"}


def state_dir_target_reason(prog, t, cwd, label=None):
    """A copy / link / move / extract whose DESTINATION is the state root or a project state dir (a directory target): `ln -s /x/approvals <keydir>` names the
    link after the source basename, `cp -R /x/approvals <keydir>/`, `tar -C <keydir> -xf a.tar` and `unzip -d <keydir>` create approvals/ (or closed/, guard.json ...) in it.
    The destination itself names no protected path, so the path rule cannot see it; any such write into the root or a project dir is refused (state files change
    through the skill's scripts and the Write tool, never through a directory-level copy). Targets that cannot be resolved are left to the callers."""
    if prog not in DIR_COPY_PROGS:
        return None
    p = resolve_vars(os.path.expanduser(t))
    if SUBST in p or "$" in p:
        return None
    if not os.path.isabs(p):
        if cwd is None:
            return None
        p = os.path.join(cwd, p)
    rp = real(p)
    if under(rp, DT_HOME) and len(_comps(rp)) <= len(_comps(DT_HOME)) + 1:           # the root, a project dir, or a new entry directly in the root (git clone <src> <root>/x)
        return ("%s into %s, the delivery state's root / project directory, could create a protected entry there (approvals/, closed/, guard.json, sessions/ - the name "
                "comes from the source): state files change only through the skill's scripts" % (label or prog, rp))
    return None


def hardlink_sources(a, prog):
    """Source arguments of a command that makes a hard link (ln without -s, link, cp -l / --link). Writing through the
    link edits the same file, so a protected source must not be linked."""
    flags = [t for t in a[1:] if t.startswith("-") and t != "-"]
    pos = [t for t in a[1:] if not t.startswith("-") or t == "-"]
    if prog == "link":
        return pos[:1]
    if prog == "ln":
        if any(f == "--symbolic" or (not f.startswith("--") and "s" in f[1:]) for f in flags):
            return []
    elif prog == "cp":
        if not any(f == "--link" or (not f.startswith("--") and "l" in f[1:]) for f in flags):
            return []
    else:
        return []
    tflag = "-t" in a or any(f.startswith("--target-directory") for f in flags)
    return pos if tflag else (pos[:-1] if len(pos) > 1 else pos)


def hardlink_reason(src, cwd):
    p = resolve_vars(os.path.expanduser(src))
    if SUBST in p or "$" in p:
        return None
    if not os.path.isabs(p):
        if cwd is None:
            return None
        p = os.path.join(cwd, p)
    rp = real(p)
    if protected_state(rp):
        return ("%s is protected state: a hard link to it would let a later write edit it through the link - "
                "state files change only through the skill's scripts" % rp)
    return None


def gitconfig_paths():
    """(files, dirs) of the user's git config: git-push.sh / git-rename.sh run unsandboxed and trust these (scripts/git_safe.py), so a core.sshCommand or
    credential.helper written here would run with the user's full access. ~/.gitconfig, ~/.config/git/**, $XDG_CONFIG_HOME/git/** (Write / Edit and shell writes)."""
    xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config")
    # ~/.ssh/** (C9b): config* (ProxyCommand / LocalCommand / Match exec run client-side under the unsandboxed git-push.sh), its Include targets, config.d, keys,
    # known_hosts - no legitimate Claude write there; ssh updating known_hosts under git-push.sh is not a hooked call
    return ([os.path.join(HOME, ".gitconfig"), os.path.join(HOME, ".netrc")],
            [os.path.join(HOME, ".config", "git"), os.path.join(xdg, "git"), os.path.join(HOME, ".config", "gh"), os.path.join(xdg, "gh"),
             os.path.join(HOME, ".config", "glab-cli"), os.path.join(xdg, "glab-cli"), os.path.join(HOME, ".ssh")])


def gitconfig_protected(rp):
    files, dirs = gitconfig_paths()
    return any(under(rp, f) for f in files + dirs)


# ---------------------------------------------------------------- the configuration the hooks trust (C9b, plan.md section 4b): always on, any cwd

CLAUDE_DIR = os.path.join(HOME, ".claude")
GITCFG_WHY = ("%s is part of the configuration that the unsandboxed git-push.sh / git-rename.sh / gh / glab read and can execute from (git config, ~/.ssh, .netrc, "
              "the gh / glab configs: a core.sshCommand, ProxyCommand, credential.helper or alias there would run with full access) - tell me the setting and I change it myself")
SETTINGS_WHY = ("%s is a Claude Code settings file (hooks, permissions, sandbox): it changes only through scripts/install-hooks.sh, which the user runs in their own terminal")
SKILL_WHY = ("%s is in the deliver-ticket skill dir (hooks, scripts, stages): it is edited only from a session STARTED in the skill repo "
             "(cd ~/.claude/skills/deliver-ticket && claude; a later cd does not count) - this session's start record (<state root>/starts/<session id>) is elsewhere or missing")
REPO_SETTINGS_WHY = ("%s is the Claude Code settings file of a repo with delivery state (its project hooks and sandbox): it changes only through install-hooks.sh "
                     "project-apply / project-sandbox-apply, which the user runs in their own terminal")


def skill_dirs():
    """The skill dir as installed and the checkout this hook runs from (the same directory when the hooks are installed)."""
    return sorted({real(os.path.join(CLAUDE_DIR, "skills", "deliver-ticket")), SKILL_DIR})


def started_in_skill(payload):
    """True when this session's start record (hooks/session-record.sh, first SessionStart wins) is the skill repo or inside it. The payload cwd follows a `cd`
    (probe 2026-11-16), so it is not used. Missing / unreadable / symlinked record or starts/, a bad session id: False (fail-closed)."""
    sid = _sid(payload or {})
    if sid is None or sid.startswith("."):
        return False
    d = os.path.join(DT_HOME, "starts")
    f = os.path.join(d, sid)
    if os.path.islink(d) or os.path.islink(f) or not os.path.isfile(f):
        return False
    try:
        rec = open(f).read().strip()
    except OSError:
        return False
    if not rec.startswith("/") or "\n" in rec:
        return False
    return any(under(real(rec), s) for s in skill_dirs())


def delivery_repos():
    """repo_root of every project with delivery state (<root>/<key>/guard.json), physical paths."""
    out = []
    try:
        keys = os.listdir(DT_HOME)
    except OSError:
        return out
    for k in keys:
        gj = os.path.join(DT_HOME, k, "guard.json")
        if not os.path.isfile(gj):
            continue
        try:
            r = json.load(open(gj)).get("repo_root")
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(r, str) and r.startswith("/"):
            out.append(real(r))
    return out


def has_delivery_state(repo):
    if os.path.isfile(os.path.join(DT_HOME, "%s-%s" % (os.path.basename(repo), hashlib.sha1(repo.encode()).hexdigest()[:8]), "guard.json")):
        return True
    return any(under(repo, r) and under(r, repo) for r in delivery_repos())


_REPO_SETTINGS = (r"(.+)/\.claude/worktrees/[^/]+/\.claude/settings[^/]*\.json", r"(.+)/\.claude/settings(\.local)?\.json")


def repo_settings_file(rp):
    """True for <repo>/.claude/settings.json|settings.local.json or <repo>/.claude/worktrees/*/.claude/settings*.json of a repo WITH delivery state (another
    project's settings stay editable: the update-config workflow)."""
    flags = re.I if fs_ci(rp) else 0
    for rx in _REPO_SETTINGS:
        m = re.fullmatch(rx, rp, flags)
        if m and has_delivery_state(m.group(1)):
            return True
    return False


def claude_settings_file(rp):
    """~/.claude/settings* (settings.json, settings.local.json, the installer's manifest and backups)."""
    return under(os.path.dirname(rp), CLAUDE_DIR) and under(CLAUDE_DIR, os.path.dirname(rp)) and _cmatch("settings*", os.path.basename(rp), fs_ci(CLAUDE_DIR))


def config_reason(rp, payload):
    """A reason when the physical path rp is configuration the hooks and gate scripts trust; checked first by path_ok and nostate_path (every cwd)."""
    if gitconfig_protected(rp):
        return GITCFG_WHY % rp
    if claude_settings_file(rp):
        return SETTINGS_WHY % rp
    if any(under(rp, s) for s in skill_dirs()) and not started_in_skill(payload):
        return SKILL_WHY % rp
    if repo_settings_file(rp):
        return REPO_SETTINGS_WHY % rp
    return None


def config_roots(payload):
    """Protected paths for the removal / glob / directory-destination rule below."""
    files, dirs = gitconfig_paths()
    roots = files + dirs + [os.path.join(CLAUDE_DIR, "settings.json"), os.path.join(CLAUDE_DIR, "settings.local.json")]
    if not started_in_skill(payload):
        roots += skill_dirs()
    for r in delivery_repos():
        roots += [os.path.join(r, ".claude", "settings.json"), os.path.join(r, ".claude", "settings.local.json")]
    return roots


def config_target_reason(prog, t, cwd, payload):
    """What path_ok / nostate_path cannot see because the target is not the protected path itself: (a) rm / mv / ... of a parent of a protected path
    (`rm -rf ~/.claude/skills`, `mv ~/.claude ~/c`); (b) a glob target that could match one or a parent of one (`rm ~/.claude/settings*`); (c) a copy / link /
    extract whose destination is ~/.claude, <repo>/.claude or <repo>/.claude/worktrees/<n>/.claude of a repo with delivery state (`cp -R x/.claude <repo>/`
    is NOT caught: the destination is the repo root - known limit; the project sandbox denyWrite covers it there). Unresolvable targets: None."""
    p = resolve_vars(os.path.expanduser(t))
    if SUBST in p or "$" in p:
        return None
    if not os.path.isabs(p):
        if cwd is None:
            return None
        p = os.path.join(cwd, p)
    if _GLOB.search(p):
        parts = _comps(os.path.normpath(p))
        k = 0
        while k < len(parts) and not _GLOB.search(parts[k]):
            k += 1
        tc = _comps(real("/" + "/".join(parts[:k]))) + parts[k:]
        for root in config_roots(payload):
            rc = _comps(root)
            ci = fs_ci(root)
            if all(_cmatch(tc[i], rc[i], ci) for i in range(min(len(tc), len(rc)))):
                return "a glob in the target of %s could match %s, which is protected configuration" % (prog, root)
        return None
    rp = real(p)
    if prog in DESTRUCTIVE:
        for root in config_roots(payload):
            if under(root, rp) and rp != root:
                return "%s removes or moves %s, a parent of %s, which is protected configuration" % (prog, rp, root)
    if prog in DIR_COPY_PROGS:
        dests = [CLAUDE_DIR]
        for r in delivery_repos():
            dests.append(os.path.join(r, ".claude"))
            wt = os.path.join(r, ".claude", "worktrees")
            if under(rp, wt) and len(_comps(rp)) == len(_comps(wt)) + 2 and _cmatch(".claude", os.path.basename(rp), fs_ci(wt)):
                dests.append(rp)
        if any(under(rp, d) and under(d, rp) for d in dests):
            return ("%s into %s could create a settings file there (the name comes from the source): Claude Code settings change only through "
                    "scripts/install-hooks.sh, run by the user" % (prog, rp))
    return None


# ---------------------------------------------------------------- the plan-approval lock (milestone 1c, plan.md section 3b)

def _fold(x, ci):
    return x.casefold() if ci else x


def registered_tickets():
    """IDs that some session map names with a `ticket=` line (written only by the bind hook / session-map.sh: protected state, so Claude cannot un-register a
    ticket by renaming its ticket file) plus every tickets/<ID>.md that exists (the stricter union). Folded on a case-insensitive filesystem."""
    ci = fs_ci(DT_HOME)
    ids = set()
    try:
        for f in os.listdir(os.path.join(DT_HOME, "sessions")):
            try:
                for line in open(os.path.join(DT_HOME, "sessions", f)):
                    if line.startswith("ticket="):
                        ids.add(_fold(line.split("=", 1)[1].strip(), ci))
            except OSError:
                pass
    except OSError:
        pass
    try:
        for f in os.listdir(os.path.join(STATE, "tickets")):
            if f.endswith(".md"):
                ids.add(_fold(f[:-3], ci))
    except OSError:
        pass
    return ids


def lock_problem(tid):
    """None when ticket tid is not locked, else the reason. Locked = open (no closed/<ID>) and the plan not approved; any read / parse problem is locked."""
    if os.path.lexists(os.path.join(STATE, "closed", tid)):
        return None
    sys.path.insert(0, SKILL_SCRIPTS)
    try:
        import plan_lock
        try:
            txt = open(os.path.join(STATE, "tickets", tid + ".md")).read()
        except OSError:
            return "the ticket file tickets/%s.md is missing or unreadable (a registered ticket without its file stays locked)" % tid
        ok, why = plan_lock.plan_approved(STATE, tid, txt)
    except Exception as e:                      # fail-closed
        return "the plan lock cannot be evaluated (%s)" % e.__class__.__name__
    return None if ok else why


def plan_lock_reason(g, rp):
    """A reason when rp is inside the worktree of a ticket whose plan is not approved (or whose state cannot be read), else None."""
    wt_root = real(os.path.join(g["repo_root"], ".claude", "worktrees"))
    if not under(rp, wt_root) or rp == wt_root:
        return None
    comp = first_component(rp, wt_root)
    ci = fs_ci(wt_root)
    tid = comp
    try:
        hits = [d for d in os.listdir(wt_root) if _fold(d, ci) == _fold(comp, ci)]
        tid = hits[0] if hits else comp
    except OSError:
        pass
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", tid) or _fold(tid, ci) not in registered_tickets():
        return None
    why = lock_problem(tid)
    if why is None:
        return None
    return ("%s is in the worktree of ticket %s, whose plan is not approved (%s). Show me the plan with `%s %s --repo <repo_root>`, ask for my yes, then run "
            "`%s %s --sha <the 12 hex shown> --repo <repo_root> --session <id>` (stage 2); reading is fine" %
            (rp, tid, why, os.path.join(SKILL_SCRIPTS, "plan-hash.sh"), tid, os.path.join(SKILL_SCRIPTS, "approve-plan.sh"), tid))


def locked_tickets(g):
    """Worktree IDs (directories under <repo>/.claude/worktrees) that are registered tickets with an unapproved plan."""
    wt_root = real(os.path.join(g["repo_root"], ".claude", "worktrees"))
    ci = fs_ci(wt_root)
    reg = registered_tickets()
    out = []
    try:
        names = sorted(os.listdir(wt_root))
    except OSError:
        return out
    for d in names:
        if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", d) and _fold(d, ci) in reg and lock_problem(d):
            out.append(d)
    return out


def locked_branches(g):
    """{branch: ticket} for the branches checked out in locked ticket worktrees: moving such a ref changes the worktree's files without a write to it."""
    wt_root = real(os.path.join(g["repo_root"], ".claude", "worktrees"))
    out = {}
    for tid in locked_tickets(g):
        try:
            r = subprocess.run(["git", "-C", os.path.join(wt_root, tid), "symbolic-ref", "--short", "-q", "HEAD"], capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            continue
        if r.returncode == 0 and r.stdout.strip():
            out[r.stdout.strip()] = tid
    return out


def _branch_name(ref):
    return ref[len("refs/heads/"):] if ref.startswith("refs/heads/") else ref


def ref_move_reason(g, sub, rest, cwd):
    """A reason when a git command could move the branch checked out in a locked ticket worktree from elsewhere (`git update-ref refs/heads/<b> <sha>` from the main
    checkout): the files of that worktree change without any write to it. Git itself refuses `branch -f` / `checkout -B` / `fetch . x:<b>` for a checked-out branch
    (we refuse them too), but `update-ref` has no such guard. The final stop would be verify-record's clean-tree check (the worktree turns dirty)."""
    if sub not in ("update-ref", "branch", "fetch", "worktree"):
        return None
    pos = [t for t in rest if not t.startswith("-")]
    if sub == "worktree":
        if pos and pos[0] in ("remove", "move", "prune"):
            for t in pos[1:]:
                tp = os.path.expanduser(t)
                if not os.path.isabs(tp):
                    if cwd is None:
                        continue
                    tp = os.path.join(cwd, tp)
                why = plan_lock_reason(g, real(tp)) if (SUBST not in tp and "$" not in tp) else None
                if why:
                    return "git worktree %s on a locked ticket worktree: %s" % (pos[0], why)
        return None
    lb = locked_branches(g)
    if not lb:
        return None
    hit = None
    if sub == "update-ref":
        if "--stdin" in rest:
            return "git update-ref --stdin cannot be checked while a ticket worktree is locked (%s): approve the plan first" % ", ".join(sorted(set(lb.values())))
        words, skip = [], False
        for t in rest:
            if skip:
                skip = False
            elif t == "-m":
                skip = True
            elif not t.startswith("-"):
                words.append(t)
        hit = _branch_name(words[0]) if words else None
    elif sub == "branch":
        forcing = any(t in ("--force", "--copy", "--delete") or (t.startswith("-") and not t.startswith("--") and any(ch in t[1:] for ch in "fFCdD")) for t in rest)
        if forcing:
            hit = next((_branch_name(t) for t in pos if _branch_name(t) in lb), None)
    elif sub == "fetch":
        if "--update-head-ok" in rest or "-u" in rest:
            return "git fetch --update-head-ok could move a checked-out branch of a locked ticket worktree (%s): approve the plan first" % ", ".join(sorted(set(lb.values())))
        hit = next((_branch_name(t.rsplit(":", 1)[1]) for t in pos if ":" in t and _branch_name(t.rsplit(":", 1)[1]) in lb), None)
    if hit in lb:
        return ("git %s would move the branch %s, checked out in the worktree of ticket %s whose plan is not approved (its files would change without a write to it): "
                "approve the plan first (stage 2: plan-hash.sh, then approve-plan.sh)" % (sub, hit, lb[hit]))
    return None


RECURSIVE_ALWAYS = {"rsync", "ditto", "tar", "bsdtar", "gtar", "gnutar", "unzip", "pax", "cpio", "7z", "7za", "7zr", "7zz", "7zip"}   # their write_targets only fire when extracting / copying


def locked_ancestor_reason(g, prog, a, t, cwd):
    """A recursive copy / extract whose destination is an ancestor of a locked worktree (the repo root, <repo>/.claude, <repo>/.claude/worktrees): `rsync -a src/ <repo>/.claude/worktrees/`
    copies T1/... whatever the source is called. Non-recursive single-file cp / mv / ln / install are not affected."""
    recursive = prog in RECURSIVE_ALWAYS
    if prog == "cp":
        recursive = any(f in ("--recursive", "--archive") or (f.startswith("-") and not f.startswith("--") and any(ch in f[1:] for ch in "rRa")) for f in a[1:])
    if not recursive:
        return None
    p = resolve_vars(os.path.expanduser(t))
    if SUBST in p or "$" in p:
        return None
    if not os.path.isabs(p):
        if cwd is None:
            return None
        p = os.path.join(cwd, p)
    rp = real(p)
    repo = real(g["repo_root"])
    if not any(rp == x or (fs_ci(repo) and rp.casefold() == x.casefold()) for x in (repo, os.path.join(repo, ".claude"), os.path.join(repo, ".claude", "worktrees"))):
        return None
    locked = locked_tickets(g)
    if not locked:
        return None
    return ("%s of a directory tree into %s could create files in the worktree of %s, whose plan is not approved (a contents copy names no worktree path): "
            "approve the plan first (stage 2: plan-hash.sh, then approve-plan.sh)" % (prog, rp, ", ".join(locked)))


GITCFG_WRITE_FLAGS = {"--add", "--unset", "--unset-all", "--replace-all", "--rename-section", "--remove-section", "-e", "--edit", "--set", "set", "unset", "edit",
                      "rename-section", "remove-section"}
GITCFG_READ_FLAGS = {"--get", "--get-all", "--get-regexp", "--get-urlmatch", "-l", "--list", "get", "list", "--show-origin", "--show-scope", "--name-only"}
GITCFG_SCOPE = {"--global", "--system"}


def check_git_config(rest, cwd):
    """`git config --global|--system|--file <user git config>` with a write is blocked; reads stay allowed. Fail-closed: no read flag and two or more
    positionals (key value) is a write. `git config key value` without a scope writes the repo's .git/config, which the sandbox protects (not this rule)."""
    scoped = any(t in GITCFG_SCOPE for t in rest)
    for i, t in enumerate(rest):
        val = None
        if t in ("-f", "--file") and i + 1 < len(rest):
            val = rest[i + 1]
        elif t.startswith("--file="):
            val = t.split("=", 1)[1]
        if val is not None:
            if SUBST in val or "$" in val:
                scoped = True
            else:
                v = os.path.expanduser(val)
                if not os.path.isabs(v):
                    v = os.path.join(cwd or "/", v)
                scoped = scoped or gitconfig_protected(real(v))
    if not scoped:
        return
    pos = [t for t in rest if not t.startswith("-")]
    writes = any(t in GITCFG_WRITE_FLAGS for t in rest)
    reads = any(t in GITCFG_READ_FLAGS for t in rest)
    if writes or (not reads and len(pos) >= 2):
        block("git config --global / --system / --file on the user's git config is not run by Claude (git-push.sh trusts those files and runs them unsandboxed): "
              "tell me the setting and I change it myself; reads (--get, --list, --show-origin) are fine")


def path_ok(p, g, payload, cwd):
    """None if writing p is allowed, else a reason. A session with no open ticket is only held to the always-on rules
    (~/.claude, session / ticket-state bookkeeping); a path it uses cannot be evaluated when it holds an unresolvable
    variable, which is then allowed (known limit)."""
    bound = session_bound(payload, g, cwd)
    if SUBST in p:
        return None if bound is None else "path comes from a command substitution - use a literal absolute path"
    p = resolve_vars(os.path.expanduser(p))
    if "$" in p:
        return None if bound is None else "path has an unresolvable variable - use a literal absolute path"
    if not os.path.isabs(p):
        if cwd is None:
            return None if bound is None else "relative path after a cd that cannot be resolved - use an absolute path"
        p = os.path.join(cwd, p)
    rp = real(p)
    if rp.startswith("/dev/"):
        return None
    why = config_reason(rp, payload)
    if why:
        return why
    claude = CLAUDE_DIR
    if under(rp, claude):
        if re.match(re.escape(claude) + r"/projects/[^/]+/memory(/|$)", rp, re.I if fs_ci(claude) else 0):
            return None
        return "writes to ~/.claude/ (settings, hooks, skills) are only allowed through scripts/install-hooks.sh"
    if protected_state(rp):
        return ("%s is session / ticket-state bookkeeping: written only by the bind hook and scripts/session-map.sh, "
                "scripts/ticket-state.sh" % rp)
    why = plan_lock_reason(g, rp)
    if why:
        return why
    if bound is None:
        return None          # no open ticket in this session: Claude Code's normal behaviour (always-on rules live elsewhere)
    hint = ""
    if bound[1] == "cwd":
        hint = (" [this session never ran /deliver-ticket: it is bound to ticket %s only because its cwd is inside that worktree - "
                "cd out of the worktree (read it with absolute paths) to unbind]" % bound[0])
    repo = real(g["repo_root"])
    wt_root = os.path.join(repo, ".claude", "worktrees")
    roots = allowed_roots(g, payload, cwd)
    if under(rp, repo):
        # main checkout is never writable; only a ticket worktree inside it is
        if any(under(rp, r) and under(r, wt_root) and r != wt_root for r in roots):
            return None
        return "%s is in the main checkout - work happens in the ticket worktree%s" % (rp, hint)
    for r in roots:
        if under(rp, r):
            return None
    return ("%s is outside the allowlist (ticket worktree, state dir, tmp, scratchpad, auto-memory)%s" % (rp, hint))


# ---------------------------------------------------------------- command checks

WRITE_ALL = {"touch", "mkdir", "rm", "rmdir", "tee", "truncate", "unlink", "mkfifo", "shred"}
WRITE_SKIP1 = {"chmod", "chown", "chgrp"}
GIT_MUTATING = {"add", "commit", "checkout", "switch", "restore", "reset", "rebase", "merge",
                "cherry-pick", "stash", "apply", "am", "mv", "rm", "clean", "pull", "revert"}
GIT_OPT_ARG = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix"}
GIT_OPT_FLAG = {"--no-pager", "-p", "--paginate", "--bare", "--no-replace-objects", "--literal-pathspecs",
                "--glob-pathspecs", "--noglob-pathspecs", "--icase-pathspecs", "--no-optional-locks"}
PUSH_OK_LONG = {"--set-upstream", "--dry-run", "--tags", "--follow-tags", "--verbose", "--quiet",
                "--atomic", "--porcelain", "--progress", "--no-progress", "--thin", "--no-thin"}
HOOK_SKIP_ENV = {"HUSKY", "HUSKY_SKIP_HOOKS", "LEFTHOOK", "SKIP"}


def is_env_name(word):
    for piece in re.split(r"[=:]", word):
        b = os.path.basename(piece.rstrip("/")).lower()          # folded always: .ENV is .env on a case-insensitive filesystem
        if b.startswith(".env"):
            return True
        if b.startswith(".") and any(ch in b for ch in "*?[") and fnmatch.fnmatch(".env", b):
            return True
    return False


def is_skill_script(c):
    a = c.argv
    if not a:
        return False
    cand = a[0]
    if pname(cand) in SHELLS | {"python3", "python"} and len(a) > 1:
        cand = a[1]
    if SUBST in cand or "$" in cand:
        return False
    base = c.cwd or os.getcwd()
    return under(real(os.path.join(base, os.path.expanduser(cand))), SKILL_SCRIPTS)


def parse_git(a):
    """Return (subcommand, rest, cwd_override, global_c_values). Raises Block on odd options."""
    i, cwd_over, cvals = 1, None, []
    while i < len(a):
        t = a[i]
        if t in GIT_OPT_FLAG:
            i += 1
        elif t in ("-C", "-c") and i + 1 < len(a):
            if t == "-c":
                cvals.append(a[i + 1])
            else:
                cwd_over = a[i + 1]
            i += 2
        elif t in GIT_OPT_ARG and i + 1 < len(a):
            i += 2
        elif t.split("=")[0] in GIT_OPT_ARG:
            i += 1
        elif t.startswith("-c") and len(t) > 2 and not t.startswith("--"):
            cvals.append(t[2:])
            i += 1
        elif t.startswith("-"):
            block("git global option %r is not understood - blocked (fail-closed)" % t)
        else:
            return t, a[i + 1:], cwd_over, cvals
    return None, [], cwd_over, cvals


def check_push(rest, g):
    pos, dry, i = [], False, 0
    while i < len(rest):
        t = rest[i]
        if t == "--":
            pos += rest[i + 1:]
            break
        if t.startswith("--"):
            name = t.split("=")[0]
            if name.startswith("--force") or name in ("--mirror", "--delete", "--prune", "--no-verify",
                                                      "--repo", "--receive-pack", "--exec", "--push-option"):
                block("git push %s is not allowed (force / delete / mirror / no-verify)" % name)
            if name not in PUSH_OK_LONG:
                block("git push option %s is not on the allowed list - blocked (fail-closed)" % name)
            dry = dry or name == "--dry-run"
        elif t.startswith("-") and len(t) > 1:
            for ch in t[1:]:
                if ch in "fd":
                    block("git push -%s is not allowed (force / delete)" % ch)
                if ch not in "unvq":
                    block("git push flag -%s is not on the allowed list - blocked (fail-closed)" % ch)
                dry = dry or ch == "n"
        else:
            pos.append(t)
        i += 1
    if not pos:
        block("git push without an explicit remote - name an allowed remote (%s)" %
              ", ".join(g["remotes"]["allowed"]) or "none configured")
    remote, specs = pos[0], pos[1:]
    for r in specs:
        if r.startswith("+") or r.startswith(":"):
            block("git push refspec %r is a force or delete" % r)
    if remote in g["remotes"]["forbidden"]:
        block("push to forbidden remote %r" % remote)
    if remote not in g["remotes"]["allowed"]:
        block("push to remote %r which is not in the allowed list %s" % (remote, g["remotes"]["allowed"]))
    return dry


# Gated commands: the permission `ask` rules (user level: Bash(git push:*), glab/gh mr|pr create; a project's own Bash(git commit:*); project sandbox: the CLI_ASK list of
# scripts/install_hooks.py) match the command TEXT as a prefix. Any other spelling - git -C x push, /usr/bin/git, env / command / xargs in front,
# bash -c "...", an option between the subcommand words - does not match, and with the sandbox on it would run auto-approved. So the hook only lets
# these commands through in the one spelling the rule matches.
GATED_CLI = {"gh": [("api",), ("auth",), ("secret",), ("variable",), ("repo",), ("workflow",), ("run",), ("release",), ("alias",), ("extension",),
                    ("config",), ("issue",), ("gist",), ("label",), ("ssh-key",), ("gpg-key",), ("codespace",),
                    ("pr", "create"), ("pr", "edit"), ("pr", "comment"), ("pr", "close"), ("pr", "review"), ("pr", "reopen"), ("pr", "checkout"),
                    ("pr", "ready"), ("pr", "lock"), ("pr", "unlock")],
             "glab": [("api",), ("auth",), ("variable",), ("repo",), ("ci",), ("release",), ("alias",), ("config",), ("token",), ("issue",), ("label",),
                      ("snippet",), ("ssh-key",), ("gpg-key",),
                      ("mr", "create"), ("mr", "update"), ("mr", "note"), ("mr", "close"), ("mr", "approve"), ("mr", "reopen"), ("mr", "checkout"),
                      ("mr", "delete")]}
CLI_VALUE_OPTS = {"-R", "--repo", "--hostname"}
# C11 step 4: package installs gated by a project ask rule (dry-run project: Bash(pnpm add:*), Bash(pnpm install:*)) - the same prefix problem: probe
# pnpm_dir_flag_add / pnpm_dir_long_install (2.1.311) ran `pnpm -C <dir> add` / `pnpm --dir <dir> install` sandboxed with no prompt.
PNPM_GATED = {"add": "add", "install": "install", "i": "install"}      # spelled subcommand -> the one spelling its ask rule matches
PNPM_RUNNERS = {"npx", "pnpx", "corepack"}


def _npm_call(a, prog):
    """The shell string of `npm exec|x -c <cmd>` / `--call <cmd>` / `--call=<cmd>` (npm runs it like bash -c), else None."""
    if prog != "npm" or len(a) < 3 or a[1] not in ("exec", "x"):
        return None
    for k in range(2, len(a)):
        if a[k] in ("-c", "--call") and k + 1 < len(a):
            return a[k + 1]
        if a[k].startswith("--call="):
            return a[k][len("--call="):]
    return None


def _pnpm_in_string(cmd):
    """True when a shell string runs pnpm with a gated word after it (pnpm add / install / i, any options between)."""
    try:
        words = shlex.split(cmd)
    except ValueError:
        words = cmd.split()
    names = [pname(w) for w in words]
    return any(n == "pnpm" and any(w in PNPM_GATED for w in words[k + 1:]) for k, n in enumerate(names))


def _pnpm_args(a, prog):
    """The words after `pnpm` when this command runs pnpm - directly or through npx / pnpx / corepack / `npm exec` / `npm x` - else None."""
    if prog == "pnpm":
        return a[1:]
    if prog in PNPM_RUNNERS and len(a) > 1 and pname(a[1]) == "pnpm":
        return a[2:]
    if prog == "npm" and len(a) > 2 and a[1] in ("exec", "x"):
        i = next((k for k in range(2, len(a)) if not a[k].startswith("-")), None)          # npm exec [--yes] [--] pnpm ...
        if i is not None and pname(a[i]) == "pnpm":
            return a[i + 1:]
    return None


def _cli_positionals(toks):
    pos, i = [], 0
    while i < len(toks):
        t = toks[i]
        if t.startswith("-"):
            i += 2 if t in CLI_VALUE_OPTS else 1
        else:
            pos.append(t)
            i += 1
    return pos


def check_canonical(c):
    """Block a gated command (git push, git commit, pnpm add / install, gh / glab writes) that is not spelled the way its ask rule matches."""
    a = c.argv
    if not a:
        return
    prog = pname(a[0])
    plain = a[0] == prog and not c.prefix and not c.assigns and not c.nested
    if prog == "git":
        sub, _, _, _ = parse_git(a)
        if sub == "push":
            block("git push is not run by Claude (the repo's own hooks would run unsandboxed under the excluded git): use `%s <remote> <branch>` from the "
                  "worktree directory - it pushes HEAD to that branch of an allowed remote, with the verify record checked" % os.path.join(SKILL_SCRIPTS, "git-push.sh"))
        if sub == "branch" and any(t in ("-m", "-M", "--move") or (t.startswith("-") and not t.startswith("--") and ("m" in t[1:] or "M" in t[1:])) for t in a):
            block("git branch -m is not run by Claude (the repo's own hooks would run unsandboxed under the excluded git): use `%s <old> <new>` from the "
                  "worktree directory" % os.path.join(SKILL_SCRIPTS, "git-rename.sh"))
        # the commit gate: a project ask rule `Bash(git commit:*)` (and CLAUDE.md "never commit without asking") sees only the plain spelling; probe
        # commit_bypass_dir_flag (2.1.311): `git -C <worktree> commit` ran sandboxed with no prompt and moved the branch
        if sub == "commit" and not (plain and a[1:2] == ["commit"]):
            block("git commit is spelled so the permission ask rule `git commit` would not match it (a global option such as -C / -c / --git-dir before "
                  "`commit`, a path, a wrapper, an env assignment, bash -c / eval / $( )): run `cd <worktree>` as its own call, then plain `git commit ...` "
                  "in the next call")
    elif _npm_call(a, prog) is not None and _pnpm_in_string(_npm_call(a, prog)):
        block("npm exec -c / --call runs a shell string that installs with pnpm, so the project's permission ask rule `pnpm add` / `pnpm install` would not "
              "match it: run `cd <dir>` as its own call, then plain `pnpm add|install ...` in the next")
    elif _pnpm_args(a, prog) is not None:
        toks = _pnpm_args(a, prog)
        lead = bool(toks) and toks[0].startswith("-")
        # with an option first, its value may look like the subcommand (`pnpm -C add install`): then any gated word anywhere counts
        hit = next((t for t in toks if t in PNPM_GATED), None) if lead else (toks[0] if toks and toks[0] in PNPM_GATED else None)
        if hit and not (prog == "pnpm" and plain and toks[0] == PNPM_GATED[hit]):
            want = PNPM_GATED[hit]
            block("pnpm %s is spelled so the project's permission ask rule `pnpm %s` would not match it (an option such as -C / --dir / --filter / -w before the "
                  "subcommand, the alias `i`, a path, a wrapper such as npx / corepack / npm exec, an env assignment, bash -c / eval / $( )): run `cd <dir>` as its own "
                  "call, then plain `pnpm %s ...` in the next" % (hit, want, want))
    elif prog in GATED_CLI:
        toks = a[1:]
        pos = _cli_positionals(toks)
        def in_order(pat):             # an option with a value we do not know (gh pr -t x create) hides the words from `pos`; only an option right after
            it = iter(toks[1:])        # the first word counts (gh pr list --search review is a read: `list` is there)
            return len(pat) > 1 and toks[:1] == [pat[0]] and toks[1:2] and toks[1].startswith("-") and all(w in it for w in pat[1:])
        for pat in GATED_CLI[prog]:
            if tuple(pos[:len(pat)]) == pat or in_order(pat):
                if plain and (tuple(toks[:len(pat)]) == pat or (toks and toks[0] in ("-R", "--repo"))):
                    return
                block("%s %s is spelled so the permission ask rule would not match it (a path, a wrapper, an env assignment, bash -c / eval, or an "
                      "option between the subcommand words): write it as `%s %s ...` with -R / --repo, if any, first"
                      % (prog, " ".join(pat), prog, " ".join(pat)))


# Gate scripts (install_hooks.GATES; a unit test keeps the two lists equal): the user's yes is the permission prompt on the script's full path.
# is_skill_script exempts every script under scripts/ from the hook, and an `ask` rule matches the command TEXT as a prefix, so `bash <script>`,
# `python3 <script>`, a wrapper, or the backing module (guard_apply.py, ticket_ctl.py ticket-state) would run without that prompt. A gate action is
# allowed only as `<skill dir>/scripts/<name>.sh ...`: argv[0] literally that absolute path, no interpreter, wrapper, assignment or nesting.
GATE_SCRIPTS = {"ticket-state.sh", "guard-apply.sh", "git-push.sh", "approve-plan.sh", "git-commit.sh"}
GATE_MODULES = {"guard_apply.py": None, "ticket_ctl.py": "ticket-state", "git_push.py": None, "approve_plan.py": None, "git_commit.py": None}      # module -> the argument that makes it a gate action (None: always)


def check_gate(c):
    a = c.argv
    if not a:
        return
    cand, interp, rest = a[0], False, a[1:]
    if pname(cand) in SHELLS | {"python3", "python"}:
        words = [i for i, w in enumerate(a[1:], 1) if not w.startswith("-")]      # python3 -I script, bash -e script: the first non-option word
        if not words:
            return
        cand, interp, rest = a[words[0]], True, a[words[0] + 1:]
    if SUBST in cand or "$" in cand:
        return
    base = c.cwd or os.getcwd()
    rp = real(os.path.join(base, os.path.expanduser(cand)))
    if not under(rp, SKILL_SCRIPTS):
        return
    name = os.path.basename(rp).lower()        # recognised folded (is_skill_script and under() fold case on this filesystem); ALLOWED only byte for byte below
    if name in GATE_MODULES:
        arg = GATE_MODULES[name]
        if arg is not None and arg not in rest:
            return
        shname = {"guard_apply.py": "guard-apply.sh", "ticket_ctl.py": "ticket-state.sh", "git_push.py": "git-push.sh", "approve_plan.py": "approve-plan.sh"}[name]
        block("%s is the module behind the gate script %s: a gate action runs as `%s <args>` (full path, no interpreter), so the permission prompt "
              "on that path is the user's yes" % (name, shname, os.path.join(SKILL_SCRIPTS, shname)))
    elif name in GATE_SCRIPTS:
        want = os.path.join(SKILL_SCRIPTS, name)
        if interp or a[0] != want or c.prefix or c.assigns or c.nested:
            block("%s is a gate action and is spelled so its permission ask rule would not match it (bash / python3 in front, a relative or other "
                  "path, a wrapper, an env assignment, or inside bash -c / eval / $( )): run it exactly as `%s <args>`" % (name, want))


# The installer writes ~/.claude/settings.json and <repo>/.claude/settings.local.json. is_skill_script exempts it from the hook, so with the sandbox off
# nothing else would stop a Claude call (auto mode runs it unprompted, as with the gate scripts). A writing subcommand is blocked in every spelling and
# repo; the user runs it in their own terminal tab after reading `diff` (whether `!` passes through hooks is unverified, probe V4). Known limit: python3 -c.
INSTALLER_NAMES = {"install-hooks.sh", "install_hooks.py"}
INSTALLER_WRITING = {"apply", "uninstall", "project-apply", "project-uninstall", "project-sandbox-apply", "project-sandbox-off"}


def check_installer(c):
    a = c.argv
    if not a:
        return
    i = 0
    if pname(a[0]) in SHELLS | {"python3", "python"}:
        words = [k for k, w in enumerate(a[1:], 1) if not w.startswith("-")]
        if not words:
            return
        i = words[0]
    if pname(a[i]) in INSTALLER_NAMES:
        sub = next((w for w in a[i + 1:] if not w.startswith("-")), None)
        if sub in INSTALLER_WRITING:
            block("install-hooks.sh %s changes settings files: Claude does not run it. Show me the matching read-only command (diff, project-diff or "
                  "project-sandbox-diff) and I run `%s %s ...` myself in my own terminal tab (not with `!`), then `install-hooks.sh status`"
                  % (sub, os.path.join(SKILL_SCRIPTS, "install-hooks.sh"), sub))


def command_pushes(cmds, g):
    """Yield (Cmd, dry_run, push_cwd) for each git push; applies the git checks only to push."""
    for c in cmds:
        if c.argv and pname(c.argv[0]) == "git":
            sub, rest, over, cvals = parse_git(c.argv)
            if sub == "push":
                cwd = c.cwd
                if over and cwd:
                    cwd = real(os.path.join(cwd, over))
                yield c, check_push(rest, g), cwd, rest


def current_branch(cwd):
    try:
        r = subprocess.run(["git", "-C", cwd, "symbolic-ref", "--short", "-q", "HEAD"], capture_output=True, text=True, timeout=5)
        return r.stdout.strip() if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


PROTECTED_BRANCHES = {"main", "master", "develop", "trunk"}


def check_merge(c, over, g, all_cmds):
    """git merge is allowed only on a ticket branch (merging the base into it); never on a default/target branch."""
    for o in all_cmds:
        if o.argv and pname(o.argv[0]) == "git" and parse_git(o.argv)[0] in ("checkout", "switch"):
            block("git merge in the same command as git checkout/switch: the branch it lands on cannot be checked - run them separately")
    base = c.cwd
    if over and base:
        base = os.path.join(base, over)
    br = current_branch(base) if base else None
    if br is None:
        block("git merge: cannot tell which branch HEAD is on (detached or unknown cwd) - blocked")
    if br in PROTECTED_BRANCHES or br == g.get("base_branch"):
        block("git merge while on %r (default/target branch): merging into it is never automated" % br)


# --- recursive searches that could read .env* ---------------------------------------------------
GREP_PROGS = {"grep", "egrep", "fgrep", "ggrep", "ugrep"}
GREP_SHORT_ARG = set("ABCDdefmt")      # grep short flags that take a value (rest of the cluster or next word)
RG_SHORT_ARG = set("ABCEMTdefgjmrt")
RG_LONG_ARG = {"glob", "iglob", "type", "type-not", "type-add", "max-depth", "max-count", "max-filesize",
               "regexp", "file", "replace", "context", "after-context", "before-context", "threads", "encoding",
               "sort", "sortr", "pre", "pre-glob", "colors", "ignore-file", "path-separator", "engine",
               "context-separator", "field-context-separator", "field-match-separator", "max-columns",
               "dfa-size-limit", "regex-size-limit", "hostname-bin", "hyperlink-format"}
WALK_CAP = 50000
SEARCH_FIX = ("exclude them: grep -r --exclude='.env*' ... | rg --hidden -g '!.env*' ... | "
              "git grep ... -- ':!.env*' (rg without --hidden skips dotfiles)")


def _exclude_covers_env(glob):
    g = glob[1:] if glob.startswith("!") else glob
    while g.startswith("**/"):
        g = g[3:]
    return fnmatch.fnmatch(".env", g) and fnmatch.fnmatch(".env.example", g) and fnmatch.fnmatch(".env.local", g)


def _excluded(name, pats):
    """True when one of the exclude patterns [(glob, case_insensitive)] matches the real file name. grep --exclude, rg -g and
    git pathspec excludes are case-sensitive (probed 2026-11-11: `--exclude='.foo*'` still reads .FOO.LOCAL; git too with
    core.ignorecase=true), so an exclude of `.env*` does not exclude `.ENV.LOCAL`; only rg --iglob folds case."""
    for g, ci in pats:
        g = g[1:] if g.startswith("!") else g
        while g.startswith("**/"):
            g = g[3:]
        if (fnmatch.fnmatch(name.lower(), g.lower()) if ci else fnmatch.fnmatchcase(name, g)):
            return True
    return False


def _env_files_under(dirs, excl=()):
    """First .env* file (any case) found under the given dirs (files are checked too) that no exclude pattern really
    excludes; (path|None, overflow)."""
    seen = 0
    for d in dirs:
        if os.path.isfile(d):
            if os.path.basename(d).lower().startswith(".env") and not _excluded(os.path.basename(d), excl):
                return d, False
            continue
        for root, dnames, fnames in os.walk(d, followlinks=False):
            dnames[:] = [x for x in dnames if x != ".git"]
            for f in fnames:
                seen += 1
                if f.lower().startswith(".env") and not _excluded(f, excl):
                    return os.path.join(root, f), False
            seen += len(dnames)
            if seen > WALK_CAP:
                return None, True
    return None, False


def _search_targets(cwd, words):
    out = []
    for w in words:
        if SUBST in w or "$" in w or "`" in w:
            return None
        w = re.split(r"[*?\[]", w)[0].rsplit("/", 1)[0] if re.search(r"[*?\[]", w) else w
        path = real(os.path.join(cwd, w or "."))
        if os.path.exists(path):
            out.append(path)
    return out


def exclusion_word_idx(a, prog):
    """Indexes of words that are exclude patterns of a search command (they name .env* to skip it, not to read it)."""
    idx = set()
    if prog not in GREP_PROGS and prog != "rg" and prog != "git":
        return idx
    for i, w in enumerate(a):
        val, prev = None, a[i - 1] if i else ""
        if prog in GREP_PROGS:
            if w.startswith("--exclude="):
                val = w[10:]
            elif prev == "--exclude":
                val = w
        elif prog == "rg":
            if w.startswith("--glob=") or w.startswith("--iglob="):
                val = w.split("=", 1)[1]
            elif prev in ("-g", "--glob", "--iglob"):
                val = w
            elif w.startswith("-g") and len(w) > 2 and w[2] != "-":
                val = w[2:]
            if val is not None and not val.startswith("!"):
                val = None
        else:
            if re.match(r":(!|\^|\(exclude\))", w):
                val = w[w.index(")") + 1:] if w.startswith(":(") else w[2:]
        if val is not None and _exclude_covers_env(val):
            idx.add(i)
    return idx


def check_search(c, prog):
    """grep -r / rg --hidden / git grep must not be able to read .env* files unless excluded."""
    a, cwd = c.argv, c.cwd
    if not cwd:
        return
    if prog in GREP_PROGS:
        rec = haspat = False
        excl, pos, i, endopts = [], [], 1, False
        while i < len(a):
            t = a[i]
            i += 1
            if endopts or not t.startswith("-") or t == "-":
                pos.append(t)
            elif t == "--":
                endopts = True
            elif t.startswith("--"):
                name, eq, val = t[2:].partition("=")
                if name in ("recursive", "dereference-recursive"):
                    rec = True
                elif name == "directories" and (val or (a[i:i + 1] or [""])[0]) == "recurse":
                    rec = True
                    i += 0 if eq else 1
                elif name in ("regexp", "file"):
                    haspat = True
                    i += 0 if eq else 1
                elif name == "exclude":
                    if eq:
                        excl.append(val)
                    elif i < len(a):
                        excl.append(a[i]); i += 1
                elif name in ("exclude-from", "include", "exclude-dir", "max-count", "after-context",
                              "before-context", "context", "label", "binary-files", "devices", "color",
                              "colour", "include-dir") and not eq:
                    i += 1
            else:
                for k, ch in enumerate(t[1:]):
                    if ch in "rR":
                        rec = True
                    elif ch in GREP_SHORT_ARG:
                        rest = t[2 + k:]
                        if ch in "ef":
                            haspat = True
                        if ch == "d":
                            if (rest or (a[i:i + 1] or [""])[0]) == "recurse":
                                rec = True
                        if not rest:
                            i += 1
                        break
        if not rec:
            return
        covers = any(_exclude_covers_env(x) for x in excl)
        skip = [(x, False) for x in excl]
        words = pos if haspat else pos[1:]
        targets = _search_targets(cwd, words) if words else [cwd]
        what = "%s -r" % prog
    elif prog == "rg":
        hidden, u, haspat, globs, pos, i, endopts = False, 0, False, [], [], 1, False
        while i < len(a):
            t = a[i]
            i += 1
            if endopts or not t.startswith("-") or t == "-":
                pos.append(t)
            elif t == "--":
                endopts = True
            elif t.startswith("--"):
                name, eq, val = t[2:].partition("=")
                if name == "hidden":
                    hidden = True
                elif name == "unrestricted":
                    u += 1
                elif name in ("glob", "iglob"):
                    if not eq and i < len(a):
                        val = a[i]; i += 1
                    if val:
                        globs.append((val, name == "iglob"))
                elif name in ("regexp", "file"):
                    haspat = True
                    i += 0 if eq else 1
                elif name in RG_LONG_ARG and not eq:
                    i += 1
            else:
                for k, ch in enumerate(t[1:]):
                    if ch == "." :
                        hidden = True
                    elif ch == "u":
                        u += 1
                    elif ch in RG_SHORT_ARG:
                        rest = t[2 + k:]
                        val = rest or (a[i] if i < len(a) else "")
                        if ch == "g":
                            globs.append((val, False))
                        if ch in "ef":
                            haspat = True
                        if not rest:
                            i += 1
                        break
        if not (hidden or u >= 2):
            return                      # ripgrep skips dotfiles by default
        neg = [(g, ci) for g, ci in globs if g.startswith("!")]
        covers = any(_exclude_covers_env(g) for g, _ in neg)
        skip = neg
        words = pos if haspat else pos[1:]
        targets = _search_targets(cwd, words) if words else [cwd]
        what = "rg with hidden files enabled"
    elif prog == "git":
        sub, rest, over, _ = parse_git(a)
        if sub != "grep":
            return
        base = real(os.path.join(cwd, over)) if over else cwd
        specs = []
        if "--" in rest:
            specs = rest[rest.index("--") + 1:]
        skip = []
        for sp in specs:
            if re.match(r":(!|\^|\(exclude\))", sp):
                skip.append(((sp[sp.index(")") + 1:] if sp.startswith(":(") else sp[2:]), False))
        plain = [sp for sp in specs if not sp.startswith(":")]
        untracked = any(t in ("--untracked", "--no-index") for t in rest)
        env, over_cap = None, False
        try:
            ls = subprocess.run(["git", "-C", base, "ls-files"], capture_output=True, text=True, timeout=5).stdout.split("\n")
        except (OSError, subprocess.SubprocessError):
            ls = []
        for f in ls:
            if os.path.basename(f).lower().startswith(".env") and not _excluded(os.path.basename(f), skip) and (
                    not plain or any(f == sp.rstrip("/") or f.startswith(sp.rstrip("/") + "/") or fnmatch.fnmatch(f, sp) for sp in plain)):
                env = f
                break
        if env is None and untracked:
            env, over_cap = _env_files_under(_search_targets(base, plain) if plain else [base], skip)
        if env or over_cap:
            block("git grep could read %s - %s" % (env or "more than %d files" % WALK_CAP, SEARCH_FIX))
        return
    else:
        return
    if targets is None:
        if covers:
            return                      # an exclude that covers .env* and a target the hook cannot resolve: allowed, as before
        block("%s with a target the hook cannot resolve ($VAR / substitution) could read .env* - %s" % (what, SEARCH_FIX))
    env, over_cap = _env_files_under(targets, skip)
    if env or over_cap:
        block("%s could read %s - %s" % (what, env or "more than %d files" % WALK_CAP, SEARCH_FIX))


def check_cmd(c, g, payload, all_cmds=()):
    a = c.argv
    prog = pname(a[0]) if a else ""
    exempt = is_skill_script(c)

    for asg in c.assigns + ([x for x in a[1:] if ENV_RE.match(x)] if prog == "export" else []):
        if asg.split("=")[0] in HOOK_SKIP_ENV:
            block("%s disables git hooks - not allowed" % asg.split("=")[0])
    if prog == "export":
        pass

    # --- .env* by any shell route
    if not exempt:
        skip = exclusion_word_idx(a, prog)
        for k, w in enumerate(a + [t for _, t in c.redirs]):
            if k in skip:
                continue
            if SUBST not in w and is_env_name(w):
                block("%r touches a .env* file - key names only, via scripts/env-keys.sh" % w)
        if prog in ("python", "python3", "node", "ruby", "perl") and any(
                re.search(r"\.env(?![A-Za-z_])", w, re.I) for w in a[1:]):
            block("interpreter code mentions .env* - key names only, via scripts/env-keys.sh")

    # --- recursive searches that could cover .env*
    if not exempt and (prog in GREP_PROGS or prog in ("rg", "git")):
        check_search(c, prog)

    check_canonical(c)
    check_gate(c)
    check_installer(c)

    # --- git
    if prog == "git":
        sub, rest, over, cvals = parse_git(a)
        for cv in cvals:
            if cv.lower().startswith("core.hookspath"):
                block("git -c core.hooksPath is not allowed (disables hooks)")
        for t in rest:
            if t.startswith("--no-verify"):
                block("--no-verify is not allowed")
        if sub in ("commit", "merge", "rebase", "am", "cherry-pick"):
            for t in rest:
                if sub == "commit" and re.fullmatch(r"-[A-Za-z]*n[A-Za-z]*", t):
                    block("git commit -n is --no-verify - not allowed")
        if sub == "config":
            check_git_config(rest, c.cwd if not over else os.path.join(c.cwd or "/", over))
        if sub == "config" and any(t.startswith("alias.") or t.startswith("core.hookspath") or
                                    t.lower().startswith("core.hookspath") for t in rest):
            block("git config alias.* / core.hooksPath is not allowed")
        if sub == "push":
            check_push(rest, g)
        # C11: in a ticket worktree a commit goes through the gate (the project sandbox denies the ref store, so a sandboxed commit cannot land; the gate checks
        # the plan approval and the recorded branch, and its prompt is the user's yes)
        if sub == "commit" and isinstance(g, dict) and isinstance(g.get("repo_root"), str) and c.cwd and \
                under(real(c.cwd), real(os.path.join(g["repo_root"], ".claude", "worktrees"))):
            block("git commit in a ticket worktree runs only through the gate: show `git diff --cached --stat` in one call, then run `%s --session <id> -m "
                  "\"<message>\"` from the worktree directory in the next" % os.path.join(SKILL_SCRIPTS, "git-commit.sh"))
        if sub == "merge":
            check_merge(c, over, g, all_cmds)
        # paths a git command writes without being a mutating subcommand: --work-tree (any subcommand then acts on that tree), --output[=] (diff / log / show ...),
        # format-patch -o <dir>, archive -o <file>
        gbase = c.cwd
        if over and gbase:
            gbase = os.path.join(gbase, over)
        gpaths = []
        for i, t in enumerate(a):
            nxt = a[i + 1] if i + 1 < len(a) else None
            if t.startswith("--work-tree=") or t.startswith("--output="):
                gpaths.append(t.split("=", 1)[1])
            elif t in ("--work-tree", "--output") and nxt:
                gpaths.append(nxt)
            elif sub in ("format-patch", "archive") and t in ("-o", "--output-directory") and nxt:
                gpaths.append(nxt)
            elif sub in ("format-patch", "archive") and t.startswith("--output-directory="):
                gpaths.append(t.split("=", 1)[1])
        for gp in gpaths:
            why = path_ok(gp, g, payload, gbase)
            if why:
                block("git %s would write %s: %s" % (sub, gp, why))
        why = ref_move_reason(g, sub, rest, gbase)
        if why:
            block(why)
        if sub in GIT_MUTATING or sub in ("clone", "init", "worktree"):
            base = c.cwd
            if over and base:
                base = os.path.join(base, over)
            if sub == "worktree":
                pos = [t for t in rest if not t.startswith("-")]
                tgt = pos[1] if len(pos) > 1 and pos[0] == "add" else None
            elif sub in ("clone", "init"):
                pos = [t for t in rest if not t.startswith("-")]
                tgt = pos[-1] if (pos and (sub == "init" or len(pos) > 1)) else base
            else:
                tgt = base
            if tgt is not None and (tgt == base or os.path.isabs(tgt) or base):
                full = tgt if os.path.isabs(tgt) else (os.path.join(base, tgt) if base else tgt)
                why = path_ok(full, g, payload, c.cwd)
                if why:
                    block("git %s would write in %s: %s" % (sub, full, why))
                why = state_dir_target_reason("git " + sub, full, c.cwd) or config_target_reason("git " + sub, full, c.cwd, payload)
                if why:
                    block("git %s blocked: %s" % (sub, why))
            elif tgt is None and sub not in ("worktree",):
                pass

    # --- merge / interactive
    if prog in ("glab", "gh"):
        for x, y in zip(a, a[1:]):
            if x in ("mr", "pr") and y == "merge":
                block("%s %s merge: merging is never automated" % (prog, x))
        if "api" in a and any("merge" in w for w in a):
            block("%s api call containing 'merge' - merging is never automated" % prog)
        for x, y in zip(a, a[1:] + [""]):
            if (x in ("-d", "--description") and y == "-") or x == "--description=-":
                block("glab -d - waits on an interactive prompt (hangs); use --description-file")

    # --- writes
    if exempt:
        targets = [t for _, t in c.redirs]
    else:
        targets = [t for op, t in c.redirs if op != "<" and op != "<>"] + write_targets(a, prog, c)
    if not exempt:
        for src in hardlink_sources(a, prog):
            why = hardlink_reason(src, c.cwd)
            if why:
                block("hard link blocked: %s" % why)
    for t in targets:
        why = state_reason(prog, t, c.cwd) if not exempt else None
        if why:
            block("write blocked: %s" % why)
        why = state_dir_target_reason(prog, t, c.cwd) if not exempt else None
        if why:
            block("write blocked: %s" % why)
        why = locked_ancestor_reason(g, prog, a, t, c.cwd) if not exempt else None
        if why:
            block("write blocked: %s" % why)
        why = config_target_reason(prog, t, c.cwd, payload) if not exempt else None
        if why:
            block("write blocked: %s" % why)
        why = path_ok(t, g, payload, c.cwd)
        if why:
            block("write blocked: %s" % why)


def write_targets(a, prog, c):
    flags = [t for t in a[1:] if t.startswith("-") and t != "-"]
    pos = [t for t in a[1:] if not t.startswith("-") or t == "-"]
    out = []
    if prog in WRITE_ALL:
        out = pos
    elif prog in WRITE_SKIP1:
        out = pos[1:]
    elif prog in ("cp", "ln", "install", "rsync"):
        if "-t" in a or any(f.startswith("--target-directory") for f in flags):
            for i, t in enumerate(a):
                if t == "-t" and i + 1 < len(a):
                    out.append(a[i + 1])
                if t.startswith("--target-directory="):
                    out.append(t.split("=", 1)[1])
        elif len(pos) >= 2:
            out = [pos[-1]]
    elif prog == "mv":
        out = pos
    elif prog == "link":
        out = pos[1:2]
    elif prog == "dd":
        out = [t[3:] for t in a[1:] if t.startswith("of=")]
    elif prog in ("sed", "gsed", "perl"):
        inplace = any(f in ("-i", "--in-place") or f.startswith("-i") or f.startswith("--in-place=") or
                      (prog == "perl" and re.fullmatch(r"-[A-Za-z]*i[A-Za-z0-9.]*", f)) or
                      (prog != "perl" and re.fullmatch(r"-[A-Za-z]*i[A-Za-z0-9.]*", f)) for f in flags)
        if inplace:
            has_script = any(f in ("-e", "-f") or f.startswith("--expression") for f in flags)
            out = pos if has_script else pos[1:]
    elif prog in ("curl", "wget"):
        for i, t in enumerate(a):
            if t in ("-o", "--output", "-O") and prog == "wget" and t == "-O" and i + 1 < len(a):
                out.append(a[i + 1])
            elif t in ("-o", "--output") and prog == "curl" and i + 1 < len(a):
                out.append(a[i + 1])
        if not out and (prog == "wget" or "-O" in a or "--remote-name" in a):
            out = [c.cwd or "."]
    elif prog in ("tar", "bsdtar", "gtar", "gnutar"):
        # extraction: the first word as a cluster (`tar xf a`), any `-xf` / `-x` style cluster (`tar -C d -xf a`), or --extract; -C / --directory is the destination
        if any(re.fullmatch(r"-?[A-Za-z]*x[A-Za-z]*", t) for t in a[1:2]) or any(re.fullmatch(r"-[A-Za-z]*x[A-Za-z]*", t) for t in a[1:]) or "--extract" in a:
            ch = [a[i + 1] for i, t in enumerate(a) if t in ("-C", "--directory") and i + 1 < len(a)] + [t.split("=", 1)[1] for t in a if t.startswith("--directory=")]
            out = ch or [c.cwd or "."]
    elif prog == "unzip":
        ch = [a[i + 1] for i, t in enumerate(a) if t == "-d" and i + 1 < len(a)]
        out = ch or [c.cwd or "."]
    elif prog == "find":
        # -delete removes files under the start paths; -exec / -execdir / -ok / -okdir run a command on them: a write unless that command is a known reader.
        # -fprint* / -fls write the file named after them.
        FIND_READERS = {"cat", "grep", "egrep", "fgrep", "rg", "ls", "head", "tail", "wc", "file", "stat", "du", "diff", "cmp", "shasum", "sha1sum", "sha256sum",
                        "md5", "md5sum", "basename", "dirname", "realpath", "readlink", "test", "echo", "printf", "true"}
        writes = "-delete" in a[1:]
        for i, t in enumerate(a):
            if t in ("-exec", "-execdir", "-ok", "-okdir") and (i + 1 >= len(a) or pname(a[i + 1]) not in FIND_READERS):
                writes = True
        if writes:
            start = []
            for t in a[1:]:
                if t.startswith("-") and t != "-" or t in ("(", "!"):
                    break
                start.append(t)
            out = start or [c.cwd or "."]
        out += [a[i + 1] for i, t in enumerate(a[:-1]) if t in ("-fprint", "-fprint0", "-fprintf", "-fls")]
    elif prog == "ditto":
        out = pos[-1:] if len(pos) >= 2 else []                        # ditto [opts] src... dst, also `ditto -x archive dst`
    elif prog == "pax":
        # -r reads an archive and extracts into the cwd; -rw copies src... into the last operand. Not parsed further: the destination is the cwd or the last word.
        rflag = any(re.fullmatch(r"-[A-Za-z]*r[A-Za-z]*", t) for t in a[1:])
        wflag = any(re.fullmatch(r"-[A-Za-z]*w[A-Za-z]*", t) for t in a[1:])
        out = (pos[-1:] if wflag else [c.cwd or "."]) if rflag else []
    elif prog == "cpio":
        # -i extracts into the cwd; -p <dir> passes files through to <dir> (the last operand); -o writes an archive to stdout / -F
        if any(re.fullmatch(r"-[A-Za-z]*p[A-Za-z]*", t) for t in a[1:]) or "--pass-through" in a:
            out = pos[-1:]
        elif any(re.fullmatch(r"-[A-Za-z]*i[A-Za-z]*", t) for t in a[1:]) or "--extract" in a:
            out = [c.cwd or "."]
    elif prog in ("7z", "7za", "7zr", "7zz", "7zip"):
        if len(pos) >= 1 and pos[0] in ("x", "e"):
            out = [t[2:] for t in a[1:] if t.startswith("-o") and len(t) > 2] or [c.cwd or "."]
    return out


# C11d: Bash tool parameters that widen the sandbox for one call. Probe bash_allowed_domains_param (Claude Code 2.1.311, 2026-11-18): in auto mode a call with
# allowed_domains reached a host outside the project allowlist without a prompt. Present with any value (an empty list too) = blocked; dangerouslyDisableSandbox
# when truthy. Always on in a repo with delivery state (bound or not, also with an unreadable guard.json). On every Claude Code upgrade diff the Bash tool's
# input parameters (docs/plan.md) and add any new one that widens the sandbox here.
def sandbox_widening_reason(ti, g):
    repo = g["repo_root"] if isinstance(g, dict) and isinstance(g.get("repo_root"), str) else "<repo>"
    inst = os.path.join(SKILL_DIR, "scripts", "install-hooks.sh")
    add = ("ask the user to add the host to the project allowlist in their own terminal: %s project-sandbox-diff --repo %s --domains <host>, "
           "then %s project-sandbox-apply --repo %s --domains <host> --confirmed (adds the host, keeps the others); a new session may be needed" % (inst, repo, inst, repo))
    if "allowed_domains" in ti:
        return "Bash parameter allowed_domains blocked: no per-call network widening. Run the call without it; if it needs a host, " + add
    if ti.get("dangerouslyDisableSandbox"):
        return "Bash parameter dangerouslyDisableSandbox blocked: no per-call sandbox escape. Run the call without it; if it cannot run sandboxed, tell the user why. For a missing host, " + add
    return None


# ---------------------------------------------------------------- modes

def mode_guard(payload, g):
    if payload.get("tool_name") != "Bash":
        return
    ti = payload.get("tool_input") or {}
    cmd = ti.get("command")
    if not isinstance(cmd, str):
        block("Bash payload without a command string - blocked (fail-closed)")
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else None
    if "DELIVER_TICKET_SELFTEST" in cmd:
        block("self-test marker DELIVER_TICKET_SELFTEST - this block is expected and proves the hooks run")
    why = sandbox_widening_reason(ti, g)
    if why:
        block(why)
    try:
        cmds = analyze(cmd, cwd)
    except ParseError as e:
        block("cannot parse the command (%s) - blocked, rewrite it more simply" % e)
    if g is None:
        # guard.json exists but is unusable: only the skill's own scripts may run
        if all(is_skill_script(c) for c in cmds if c.argv):
            return
        block("guard.json is unreadable - fix it (scripts/validate-guard.py) before running other commands")
    for c in cmds:
        check_cmd(c, g, payload, cmds)


def mode_verify(payload, g):
    if payload.get("tool_name") != "Bash":
        return
    cmd = (payload.get("tool_input") or {}).get("command")
    if not isinstance(cmd, str):
        block("Bash payload without a command string - blocked (fail-closed)")
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else None
    try:
        cmds = analyze(cmd, cwd)
    except ParseError as e:
        block("cannot parse the command (%s) - blocked" % e)
    if g is None:
        if any(c.argv and pname(c.argv[0]) == "git" and "push" in c.argv for c in cmds):
            block("guard.json is unreadable - push blocked")
        return
    pushes = [p for p in command_pushes(cmds, g) if not p[1]]
    if not pushes:
        return
    v = g["verify"]
    keys = v.get("on_push") or []
    if not keys:
        return
    for k in keys:
        if not v.get(k):
            block("verify.on_push lists %r but verify.%s has no command" % (k, k))
    for p in pushes:
        run_cwd = p[2] or cwd or os.getcwd()
        why = verify_record_problem(g, run_cwd, keys, p[3])
        if why:
            block("%s - push blocked. Stage 4 records the result: `%s <ID> --guard <state>/guard.json` from a clean, committed worktree (it runs the verify.on_push "
                  "commands sandboxed and writes evidence/<ID>/verify.json)" % (why, os.path.join(SKILL_SCRIPTS, "verify-record.sh")))


def push_sources(rest, where):
    """The refs a `git push` (arguments after `push`, already vetted by check_push) sends, as (list of source refs, problem). A problem means the
    sources cannot be determined statically, so the record cannot vouch for them (fail-closed)."""
    pos, i = [], 0
    while i < len(rest):
        t = rest[i]
        if t == "--":
            pos += rest[i + 1:]
            break
        if t == "--tags":
            return None, "git push --tags sends tags that the verify record does not cover"
        if not t.startswith("-"):
            pos.append(t)
        i += 1
    remote, specs = pos[0], pos[1:]
    if not specs:                                  # the current branch - unless the config redirects what a bare push sends
        for key, bad in (("push.default", lambda out: out.strip() == "matching"), ("remote.%s.push" % remote, lambda out: bool(out.strip()))):
            try:
                r = subprocess.run(["git", "-C", where, "config", "--get-all", key], capture_output=True, text=True, timeout=10)
            except (OSError, subprocess.SubprocessError):
                return None, "cannot read git config %s" % key
            if bad(r.stdout):
                return None, "git config %s makes a bare push send more than the current branch" % key
        return ["HEAD"], None
    srcs = []
    for s in specs:
        src = s.split(":", 1)[0]
        if not src or src.startswith("-") or any(ch in s for ch in "*?["):
            return None, "refspec %r cannot be resolved statically (delete, option or wildcard)" % s
        srcs.append(src)
    return srcs, None


def verify_record_problem(g, run_cwd, keys, rest=()):
    """None when evidence/<ID>/verify.json proves verify.on_push passed for the tree about to be pushed, else the reason. Reads JSON and runs
    `git rev-parse` only: it executes nothing from the worktree (a Claude-edited script run here would be unsandboxed). Fail-closed on anything odd.
    The record is tamper-evident, not tamper-proof: evidence/ is sandbox-writable (plan.md, milestone 1c, #1)."""
    base = real(os.path.join(g["repo_root"], ".claude", "worktrees"))
    where = real(run_cwd)
    if not under(where, base) or where == base:
        return "cannot tell the ticket from %s (push from the ticket's worktree directory)" % run_cwd
    tid = os.path.relpath(where, base).split(os.sep)[0]
    path = os.path.join(STATE, "evidence", tid, "verify.json")
    try:
        with open(path) as f:
            rec = json.load(f)
        results = rec["results"]
        rtree = rec["tree"]
        if not isinstance(results, dict) or not isinstance(rtree, str) or rec.get("id") != tid:
            raise ValueError("unexpected shape")
    except (OSError, ValueError, KeyError, TypeError) as e:
        return "no usable verify record for %s (%s: %s)" % (tid, os.path.basename(os.path.dirname(path)) + "/verify.json", e.__class__.__name__)
    srcs, why = push_sources(list(rest), where) if rest else (["HEAD"], None)
    if why:
        return why
    for src in srcs:                                # every ref the push sends must have exactly the recorded tree, not only HEAD
        try:
            r = subprocess.run(["git", "-C", where, "rev-parse", "--verify", "-q", src + "^{tree}"], capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.SubprocessError) as e:
            return "cannot read the tree of %s in %s (%s)" % (src, where, e)
        if r.returncode != 0 or r.stdout.strip() != rtree:
            return "the pushed %s is not the tree of the verify record for %s (HEAD changed since it was recorded, or another ref is pushed)" % (src, tid)
    for k in keys:
        res = results.get(k)
        if not isinstance(res, dict) or res.get("rc") != 0:
            return "verify %s did not pass in the record for %s" % (k, tid)
        if res.get("cmd_sha256") != hashlib.sha256(g["verify"][k].encode()).hexdigest():
            return "verify.%s changed since the record for %s was made" % (k, tid)
    return None


def mode_wguard(payload, g):
    event = payload.get("hook_event_name")
    tool = payload.get("tool_name")
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else None
    if event == "PostToolUse":
        if tool == "EnterWorktree" and g is not None:
            record_worktree(payload, g)
        return
    if tool not in ("Edit", "Write", "NotebookEdit", "MultiEdit"):
        return
    ti = payload.get("tool_input") or {}
    p = ti.get("file_path") or ti.get("notebook_path")
    if not isinstance(p, str) or not p:
        block("%s without file_path / notebook_path - blocked (fail-closed)" % tool)
    if is_env_name(p):
        block("%s on a .env* file - not allowed; tell me which key to add and I do it" % tool)
    if g is None:
        rp = real(os.path.join(cwd or "/", p))
        if protected_state(rp):
            block("%s is protected state - a broken guard.json is replaced with scripts/guard-apply.sh (candidate: "
                  "<state>/guard.candidate.json)" % rp)
        if under(rp, DT_HOME):
            return
        block("guard.json is unreadable - only the state dir may be written until it is fixed")
    why = path_ok(p, g, payload, cwd)
    if why:
        block("%s blocked: %s" % (tool, why))


def nostate_path(p, cwd, payload):
    """Repo without delivery state, payload names the state root or a protected configuration path (lib.sh dt_nostate): protected_state and
    config_reason apply. Blocks on a target it cannot resolve only when the text names the state root."""
    p = resolve_vars(os.path.expanduser(p))
    if SUBST in p or "$" in p:
        if not NAMED:
            return
        block("write target %r has a variable or command substitution and the command names the state root - "
              "use a literal absolute path" % p)
    if not os.path.isabs(p):
        if cwd is None:
            if not NAMED:
                return
            block("relative path %r after a cd that cannot be resolved and the command names the state root - "
                  "use an absolute path" % p)
        p = os.path.join(cwd, p)
    rp = real(p)
    if protected_state(rp):
        block("%s is session / ticket-state bookkeeping: written only by the bind hook and scripts/session-map.sh, "
              "scripts/ticket-state.sh" % rp)
    why = config_reason(rp, payload)
    if why:
        block(why)


def mode_nostate(payload):
    """Called by hooks/lib.sh dt_nostate in a repo with no guard.json (or no git repo), only when the payload names the
    state root. Does not read guard.json and does not depend on STATE."""
    tool = payload.get("tool_name")
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else None
    ti = payload.get("tool_input") or {}
    if tool in ("Edit", "Write", "NotebookEdit", "MultiEdit"):
        p = ti.get("file_path") or ti.get("notebook_path")
        if not isinstance(p, str) or not p:
            block("%s without file_path / notebook_path - blocked (fail-closed)" % tool)
        nostate_path(p, cwd, payload)
    elif tool == "Bash":
        cmd = ti.get("command")
        if not isinstance(cmd, str):
            block("Bash payload without a command string - blocked (fail-closed)")
        try:
            cmds = analyze(cmd, cwd)
        except ParseError as e:
            if not NAMED:
                return
            block("cannot parse the command (%s) and it names the state root - blocked, rewrite it more simply" % e)
        for c in cmds:
            a = c.argv
            prog = pname(a[0]) if a else ""
            check_gate(c)
            check_installer(c)
            if prog == "git":
                sub, rest, over, _ = parse_git(a)
                if sub == "config":
                    check_git_config(rest, c.cwd if not over else os.path.join(c.cwd or "/", over))
            if is_skill_script(c):
                targets = [t for _, t in c.redirs]
            else:
                targets = [t for op, t in c.redirs if op not in ("<", "<>")] + write_targets(a, prog, c)
            if not is_skill_script(c):
                for src in hardlink_sources(a, prog):
                    why = hardlink_reason(src, c.cwd)
                    if why:
                        block("hard link blocked: %s" % why)
            for t in targets:
                why = (state_reason(prog, t, c.cwd) or state_dir_target_reason(prog, t, c.cwd) or config_target_reason(prog, t, c.cwd, payload)) \
                    if not is_skill_script(c) else None
                if why:
                    block("write blocked: %s" % why)
                nostate_path(t, c.cwd, payload)


def find_key(obj, names):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in names and isinstance(v, str):
                return v
        for v in obj.values():
            r = find_key(v, names)
            if r:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = find_key(v, names)
            if r:
                return r
    return None


def record_worktree(payload, g):
    sid = payload.get("session_id")
    if not (isinstance(sid, str) and re.fullmatch(r"[A-Za-z0-9._-]+", sid)):
        return
    tr = payload.get("tool_response")
    if isinstance(tr, str):
        try:
            tr = json.loads(tr)
        except ValueError:
            tr = {"_text": tr}
    wt = find_key(tr, {"worktreePath", "worktree_path", "path"})
    ti = payload.get("tool_input") or {}
    wt_root = real(os.path.join(g["repo_root"], ".claude", "worktrees"))
    cands = [wt, ti.get("path"), os.path.join(wt_root, ti["name"]) if isinstance(ti.get("name"), str) else None]
    for cand in cands:
        if isinstance(cand, str) and cand.startswith("/") and under(real(cand), wt_root):
            d = os.path.join(DT_HOME, "sessions")
            os.makedirs(d, exist_ok=True)
            f = os.path.join(d, sid)
            held = old_binding(read_map(sid), os.path.basename(STATE))
            if held:
                # the same hole as the bind hook, by another route: rewriting project= would hide the old project's ticket= lines from it.
                # PostToolUse cannot block; leave the map alone (the old project stays guarded) and say so on stderr.
                print("deliver-ticket: EnterWorktree entered %s, but this session is still bound to ticket %s in project %s, so the session map was "
                      "not rewritten for this project: close or pause that ticket, or start a new session." % (real(cand), held[0], held[1]), file=sys.stderr)
                return
            keep = []
            try:
                keep = [l for l in open(f).read().splitlines() if not l.startswith(("worktree=", "project="))]
            except OSError:
                pass
            keep += ["project=%s" % os.path.basename(STATE), "worktree=%s" % real(cand)]
            with open(f, "w") as fh:
                fh.write("\n".join(keep) + "\n")
            return
    print("deliver-ticket: EnterWorktree finished but no worktree path under %s was found in the payload; "
          "session map not updated" % wt_root, file=sys.stderr)


def _field(txt, name):
    m = re.search(r"^\s*%s:\s*(\S.*)$" % name, txt, re.M)
    return m.group(1).strip() if m else None


def _intake_tickets():
    """Tickets of this project that have no worktree yet and are still open (stage 0-1)."""
    out = []
    tdir = os.path.join(STATE, "tickets")
    try:
        names = sorted(os.listdir(tdir))
    except OSError:
        return out
    for n in names:
        if not n.endswith(".md") or not re.fullmatch(r"[A-Za-z0-9._-]+", n[:-3]):
            continue
        try:
            txt = open(os.path.join(tdir, n)).read()
        except OSError:
            continue
        wt = (_field(txt, "worktree") or "").split()
        wt = wt[0] if wt else ""
        state = (_field(txt, "state") or "").split()
        state = state[0] if state else ""
        if wt == "none" and state not in ("done", "cancelled", "split"):
            out.append((n[:-3], _field(txt, "stage") or "unknown", _field(txt, "next") or "unknown",
                        os.path.join(tdir, n)))
    return out


def _emit(text):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text}}))


def mode_session(payload, g):
    sid = payload.get("session_id")
    if not (isinstance(sid, str) and re.fullmatch(r"[A-Za-z0-9._-]+", sid)):
        return
    fields = {}
    try:
        fields = dict(l.split("=", 1) for l in open(os.path.join(DT_HOME, "sessions", sid)).read().splitlines()
                      if "=" in l)
    except OSError:
        pass
    # the worktree is named after the ticket ID, so the ticket is known even if nobody wrote ticket=
    ticket = fields.get("ticket") or (os.path.basename(fields["worktree"].rstrip("/")) if fields.get("worktree") else None)
    proj = fields.get("project") or os.path.basename(STATE)
    if not ticket:
        # no session map yet (stages 0-1, before the worktree): look for tickets still in intake
        cands = _intake_tickets()
        if not cands:
            return
        lines = "; ".join("%s (stage %s, next: %s, file %s)" % c for c in cands)
        if len(cands) == 1:
            who = "the only ticket of this project still in intake is %s" % lines
        else:
            who = "tickets of this project still in intake (this session may be on one of them - ask me which): %s" % lines
        _emit("deliver-ticket: the conversation was compacted and no worktree session is recorded; %s. "
              "If this session was running /deliver-ticket, read %s/SKILL.md section 2 (hard rules), the ticket file, "
              "then the stage file it names (%s/stages/). Do not work from memory of the earlier conversation."
              % (who, SKILL_DIR, SKILL_DIR))
        return
    if not re.fullmatch(r"[A-Za-z0-9._-]+", ticket) or not re.fullmatch(r"[A-Za-z0-9._-]+", proj):
        return
    tf = os.path.join(DT_HOME, proj, "tickets", ticket + ".md")
    stage = nxt = "unknown"
    try:
        txt = open(tf).read()
        stage = _field(txt, "stage") or stage
        nxt = _field(txt, "next") or nxt
    except OSError:
        pass
    _emit("deliver-ticket: this session (id %s) works on ticket %s (project %s), stage %s; next: %s. "
          "The conversation was compacted and the skill text is gone. Before doing anything: "
          "read %s/SKILL.md section 2 (hard rules), read %s, then the stage file it names "
          "(%s/stages/). Do not work from memory of the earlier conversation."
          % (sid, ticket, proj, stage, nxt, SKILL_DIR, tf, SKILL_DIR))


def old_binding(lines, proj):
    """(token, old project) when this session's map is bound to ANOTHER project and that binding still holds, else None. Holds = an open ticket
    (no closed/<tok> marker) that is not paused-with-no-worktree, in an old project whose state dir exists; an unreadable old guard.json counts as
    holding (fail-closed). Dropping such a map would make the old project's main checkout writable for the session, unprompted."""
    old = next((v for k, v in lines if k == "project" and v != proj), None)
    if old is None:
        return None
    ostate = os.path.join(DT_HOME, old)
    if not os.path.isdir(ostate):
        return None
    try:
        with open(os.path.join(ostate, "guard.json")) as f:
            wt_root = real(os.path.join(json.load(f)["repo_root"], ".claude", "worktrees"))
    except Exception:
        wt_root = None
    paused = {v for k, v in lines if k == "paused"}
    toks = [v for k, v in lines if k == "ticket" and TOKEN_RE.fullmatch(v)]
    if wt_root:
        for k, v in lines:
            if k == "worktree":
                w = real(v)
                if under(w, wt_root) and first_component(w, wt_root) != ".":
                    toks.append(first_component(w, wt_root))
    for t in toks:
        if os.path.exists(os.path.join(ostate, "closed", t)):
            continue
        if wt_root and t in paused and not os.path.isdir(os.path.join(wt_root, t)):
            continue
        return t, old
    return None


def mode_bind(payload, g):
    """UserPromptSubmit: `/deliver-ticket <token> ...` (or its expanded `<command-name>` form) binds this session to <token> (the first argument; a file path
    gives its basename). `init` binds nothing. Stores only the token, never the prompt. A later prompt for the same
    token un-pauses it. Silent on anything else."""
    sid = _sid(payload)
    prompt = payload.get("prompt")
    if not sid or not isinstance(prompt, str):
        return
    m = re.match(r"\s*/deliver-ticket[ \t]+(\S+)", prompt)
    if not m and re.search(r"<command-name>\s*/?deliver-ticket\s*</command-name>", prompt):
        m = re.search(r"<command-args>\s*(\S+)", prompt)      # a slash command that reaches the hook already expanded
    if not m:
        return
    tok = m.group(1).strip("\"'")
    if tok == "init":
        return
    if "/" in tok or tok.endswith(".md"):
        tok = re.sub(r"\.md$", "", os.path.basename(tok))
    if not TOKEN_RE.fullmatch(tok):
        return
    proj = os.path.basename(STATE)
    lines = read_map(sid)
    held = old_binding(lines, proj)
    if held:
        # the hook cannot refuse a prompt: leave the map alone (the old project stays guarded, this one stays unbound; stage 0 check 10 fails
        # closed) and tell the session why. Plain stdout of a UserPromptSubmit hook is added to Claude's context (hooks docs, exit code 0).
        print("deliver-ticket: this session is still bound to ticket %s in project %s, so it was not bound to %s: close or pause that ticket "
              "(ticket-state.sh / session-map.sh pause), or start a new session for this project." % (held[0], held[1], tok))
        return
    if any(k == "project" and v != proj for k, v in lines):
        lines = []                                   # the session moved to another project and the old binding no longer holds: start a fresh map
    if not any(k == "project" for k, v in lines):
        lines.insert(0, ("project", proj))
    if ("ticket", tok) not in lines:
        lines.append(("ticket", tok))
    lines = [kv for kv in lines if kv != ("paused", tok)]
    write_map(sid, lines)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        try:
            payload = json.load(sys.stdin)
            assert isinstance(payload, dict)
        except Exception:
            if mode in ("session", "bind"):
                return 0
            block("payload is not valid JSON - blocked (fail-closed)")
        if mode == "nostate":
            mode_nostate(payload)
            return 0
        g = load_guard()
        {"guard": mode_guard, "verify": mode_verify, "wguard": mode_wguard,
         "session": mode_session, "bind": mode_bind}[mode](payload, g)
    except Block as e:
        print("deliver-ticket: %s" % e, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
