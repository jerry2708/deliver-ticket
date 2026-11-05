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
import json
import os
import re
import shlex
import signal
import subprocess
import sys

HOME = os.path.realpath(os.path.expanduser("~"))
STATE = os.environ.get("DT_STATE_DIR", "")
DT_HOME = os.path.realpath(os.environ.get("DT_HOME") or os.path.join(HOME, ".local/share/deliver-ticket"))
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


class Cmd:
    def __init__(self, argv, redirs, cwd, assigns):
        self.argv, self.redirs, self.cwd, self.assigns = argv, redirs, cwd, assigns


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
        argv, redirs, assigns = [], [], []
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
            elif not argv and v in KEYWORDS:
                pass
            elif not argv and v == "export":
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
            out.append(Cmd(argv, redirs, cwd, assigns))
            continue
        c = Cmd(argv, redirs, cwd, assigns)
        out.append(c)
        prog = os.path.basename(argv[0]) if argv else ""
        if prog in SHELLS and "-c" in argv:
            idx = argv.index("-c")
            if idx + 1 < len(argv):
                out += analyze(argv[idx + 1], cwd, depth + 1)
        elif prog == "eval":
            out += analyze(" ".join(argv[1:]), cwd, depth + 1)
    return out


# ---------------------------------------------------------------- allowlist

def under(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def real(path):
    return os.path.realpath(path)


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
        rel = os.path.relpath(real(cwd), wt_root).split(os.sep)[0]
        roots.append(os.path.join(wt_root, rel))
    return roots


def path_ok(p, g, payload, cwd):
    """None if writing p is allowed, else a reason."""
    if SUBST in p:
        return "path comes from a command substitution - use a literal absolute path"
    p = resolve_vars(os.path.expanduser(p))
    if "$" in p:
        return "path has an unresolvable variable - use a literal absolute path"
    if not os.path.isabs(p):
        if cwd is None:
            return "relative path after a cd that cannot be resolved - use an absolute path"
        p = os.path.join(cwd, p)
    rp = real(p)
    if rp.startswith("/dev/"):
        return None
    claude = os.path.join(HOME, ".claude")
    if under(rp, claude):
        if re.match(re.escape(claude) + r"/projects/[^/]+/memory(/|$)", rp):
            return None
        return "writes to ~/.claude/ (settings, hooks, skills) are only allowed through scripts/install-hooks.sh"
    repo = real(g["repo_root"])
    wt_root = os.path.join(repo, ".claude", "worktrees")
    roots = allowed_roots(g, payload, cwd)
    if under(rp, repo):
        # main checkout is never writable; only a ticket worktree inside it is
        if any(under(rp, r) and under(r, wt_root) and r != wt_root for r in roots):
            return None
        return "%s is in the main checkout - work happens in the ticket worktree" % rp
    for r in roots:
        if under(rp, r):
            return None
    return ("%s is outside the allowlist (ticket worktree, state dir, tmp, scratchpad, auto-memory)" % rp)


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
        b = os.path.basename(piece.rstrip("/"))
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
    if os.path.basename(cand) in SHELLS | {"python3", "python"} and len(a) > 1:
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


def command_pushes(cmds, g):
    """Yield (Cmd, dry_run, push_cwd) for each git push; applies the git checks only to push."""
    for c in cmds:
        if c.argv and os.path.basename(c.argv[0]) == "git":
            sub, rest, over, cvals = parse_git(c.argv)
            if sub == "push":
                cwd = c.cwd
                if over and cwd:
                    cwd = real(os.path.join(cwd, over))
                yield c, check_push(rest, g), cwd


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
        if o.argv and os.path.basename(o.argv[0]) == "git" and parse_git(o.argv)[0] in ("checkout", "switch"):
            block("git merge in the same command as git checkout/switch: the branch it lands on cannot be checked - run them separately")
    base = c.cwd
    if over and base:
        base = os.path.join(base, over)
    br = current_branch(base) if base else None
    if br is None:
        block("git merge: cannot tell which branch HEAD is on (detached or unknown cwd) - blocked")
    if br in PROTECTED_BRANCHES or br == g.get("base_branch"):
        block("git merge while on %r (default/target branch): merging into it is never automated" % br)


def check_cmd(c, g, payload, all_cmds=()):
    a = c.argv
    prog = os.path.basename(a[0]) if a else ""
    exempt = is_skill_script(c)

    for asg in c.assigns + ([x for x in a[1:] if ENV_RE.match(x)] if prog == "export" else []):
        if asg.split("=")[0] in HOOK_SKIP_ENV:
            block("%s disables git hooks - not allowed" % asg.split("=")[0])
    if prog == "export":
        pass

    # --- .env* by any shell route
    if not exempt:
        for w in a + [t for _, t in c.redirs]:
            if SUBST not in w and is_env_name(w):
                block("%r touches a .env* file - key names only, via scripts/env-keys.sh" % w)
        if prog in ("python", "python3", "node", "ruby", "perl") and any(
                re.search(r"\.env(?![A-Za-z_])", w) for w in a[1:]):
            block("interpreter code mentions .env* - key names only, via scripts/env-keys.sh")

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
        if sub == "config" and any(t.startswith("alias.") or t.startswith("core.hookspath") or
                                    t.lower().startswith("core.hookspath") for t in rest):
            block("git config alias.* / core.hooksPath is not allowed")
        if sub == "push":
            check_push(rest, g)
        if sub == "merge":
            check_merge(c, over, g, all_cmds)
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
    for t in targets:
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
    elif prog == "tar":
        if any(re.fullmatch(r"-?[A-Za-z]*x[A-Za-z]*", t) for t in a[1:2]) or "-x" in a or "--extract" in a:
            ch = [a[i + 1] for i, t in enumerate(a) if t == "-C" and i + 1 < len(a)]
            out = ch or [c.cwd or "."]
    elif prog == "unzip":
        ch = [a[i + 1] for i, t in enumerate(a) if t == "-d" and i + 1 < len(a)]
        out = ch or [c.cwd or "."]
    return out


# ---------------------------------------------------------------- modes

def mode_guard(payload, g):
    if payload.get("tool_name") != "Bash":
        return
    cmd = (payload.get("tool_input") or {}).get("command")
    if not isinstance(cmd, str):
        block("Bash payload without a command string - blocked (fail-closed)")
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else None
    if "DELIVER_TICKET_SELFTEST" in cmd:
        block("self-test marker DELIVER_TICKET_SELFTEST - this block is expected and proves the hooks run")
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
        if any(c.argv and os.path.basename(c.argv[0]) == "git" and "push" in c.argv for c in cmds):
            block("guard.json is unreadable - push blocked")
        return
    pushes = [p for p in command_pushes(cmds, g) if not p[1]]
    if not pushes:
        return
    v = g["verify"]
    keys = v.get("on_push") or []
    timeout = int(v.get("timeout_sec") or 300)
    run_cwd = pushes[0][2] or cwd or os.getcwd()
    for k in keys:
        cmdline = v.get(k)
        if not cmdline:
            block("verify.on_push lists %r but verify.%s has no command" % (k, k))
        try:
            p = subprocess.Popen(cmdline, shell=True, cwd=run_cwd, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, start_new_session=True)
            try:
                out, _ = p.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.communicate()
                block("verify %s timed out after %ss - push blocked" % (k, timeout))
        except OSError as e:
            block("verify %s could not start (%s) - push blocked" % (k, e))
        if p.returncode != 0:
            tail = "\n".join((out or "").splitlines()[-60:])
            block("verify %s failed (exit %s) in %s - push blocked. Last output:\n%s" %
                  (k, p.returncode, run_cwd, tail))


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
        if under(real(os.path.join(cwd or "/", p)), DT_HOME):
            return
        block("guard.json is unreadable - only the state dir may be written until it is fixed")
    why = path_ok(p, g, payload, cwd)
    if why:
        block("%s blocked: %s" % (tool, why))


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
    _emit("deliver-ticket: this session works on ticket %s (project %s), stage %s; next: %s. "
          "The conversation was compacted and the skill text is gone. Before doing anything: "
          "read %s/SKILL.md section 2 (hard rules), read %s, then the stage file it names "
          "(%s/stages/). Do not work from memory of the earlier conversation."
          % (ticket, proj, stage, nxt, SKILL_DIR, tf, SKILL_DIR))


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        try:
            payload = json.load(sys.stdin)
            assert isinstance(payload, dict)
        except Exception:
            if mode == "session":
                return 0
            block("payload is not valid JSON - blocked (fail-closed)")
        g = load_guard()
        {"guard": mode_guard, "verify": mode_verify, "wguard": mode_wguard,
         "session": mode_session}[mode](payload, g)
    except Block as e:
        print("deliver-ticket: %s" % e, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
