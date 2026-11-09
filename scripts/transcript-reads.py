#!/usr/bin/env python3
"""Check a Claude Code session transcript against the intake rule "repo notes are not searched for the ticket".

usage: transcript-reads.py <session.jsonl> [--under PREFIX ...] [--ticket ID [--title WORD ...]] [--code-root DIR ...] [--eval-run HOME]
  --under PREFIX   list every Read / Grep / Glob / Bash call that mentions the path, with or without a trailing slash
                   (default `docs`; a multi-segment prefix such as node_modules/next/dist/docs is matched as written).
                   Exclusions do not count: `':!docs'`, `--exclude-dir=docs`, `-g '!docs'`.
  --ticket ID      also list every search (Grep, Glob, Bash grep / rg / ag / ack / git grep) that contains the ticket ID or a
                   --title word (case-insensitive) AND whose target can reach a note directory. A target cannot reach it when it is
                   a single named file, a path outside the repo (state dir, /tmp, scratchpad), an ignored directory
                   (.playwright-mcp, evidence, node_modules, .git ...), a code path (--code-root, default apps packages src lib app
                   server client scripts), or a whole-repo search whose exclusions cover every --under prefix. A search with no
                   path (the cwd), `.` or a directory that is none of those can reach it. Targets that hold a $VAR are counted in
                   a separate line and not listed. `git log --grep` and a grep that filters stdin are not file searches.
  --eval-run HOME  eval-run hygiene (phase 6): also list every call that mentions a path under `dt-runs/` other than HOME
                   (another run's home, `inputs/`, `runs/`, the eval root itself), and every call that mentions the skill's `evals/`
                   directory or its answer-key files (`sample-tiers`, `truth.json`); every call that mentions `.claude/worktrees` (also
                   `git -C <it>`) or a `<type>/retro-N` branch name (finished tickets of the test project are visible from the main
                   checkout). A plain `git worktree list` / `git branch` is listed too, as REVIEW only (the scorer does not invalidate the
                   run for it). `~`, `$HOME` and `${HOME}` are expanded.
Calls whose tool_result is an error (is_error) did not run and are not counted; the ones that would have been flagged are named in one line as attempts. Only tool calls are read, never their
results. Exit 0 = nothing listed, 1 = at least one call listed (read it: technical docs by API / symbol and knowledge sources opened by
path are allowed), 2 = bad input.
"""
import argparse
import json
import re
import shlex
import sys

DEFAULT_CODE_ROOTS = ["apps", "packages", "src", "lib", "app", "server", "client", "scripts"]
OUTSIDE_MARKERS = ("/.local/share/deliver-ticket/", "/.local/share/dt-runs/", "/tmp/", "/private/tmp/", "/scratchpad/", "/.claude/projects/")
IGNORED_DIRS = {".playwright-mcp", "evidence", "node_modules", ".git", ".next", ".mastra", "dist"}
SEARCHERS = {"grep", "egrep", "fgrep", "rg", "ag", "ack"}
OPT_ARG = {"-e", "-f", "-m", "-A", "-B", "-C", "-d", "-D", "-g", "-t", "-T", "--include", "--exclude", "--exclude-dir",
           "--exclude-from", "--file", "--regexp", "--max-count", "--glob", "--iglob", "--type", "--type-not", "--max-depth"}
PATTERN_OPT = {"-e", "-f", "--regexp", "--file"}
EXCL_PATHSPEC = re.compile(r"^:(!|\^|\(exclude\))")
EXCL_TEXT = re.compile(r"""(:[!^][^\s'"]*|:\(exclude\)[^\s'"]*|--exclude(?:-dir)?[= ]['"]?[^\s'"]+|(?:-g|--glob|--iglob)[= ]['"]?![^\s'"]+)""")


def calls(obj):
    if isinstance(obj, dict):
        if obj.get("type") == "tool_use" and isinstance(obj.get("input"), dict):
            yield obj.get("id"), obj.get("name", "?"), obj["input"]
        for v in obj.values():
            yield from calls(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from calls(v)


def errored_ids(obj, out):
    if isinstance(obj, dict):
        if obj.get("type") == "tool_result" and obj.get("is_error"):
            out.add(obj.get("tool_use_id"))
        for v in obj.values():
            errored_ids(v, out)
    elif isinstance(obj, list):
        for v in obj:
            errored_ids(v, out)


def prefix_regex(p):
    p = p.strip().rstrip("/")
    if "/" in p:
        return re.compile(re.escape(p) + r"(?![\w-])")
    return re.compile(r"(?<![\w.-])" + re.escape(p) + r"(?![\w-])")


def under_text(text, raw_prefix):
    """The call text as seen by --under: library docs and exclusions are not 'touching' the note directory."""
    t = EXCL_TEXT.sub(" ", text)
    return t if "node_modules" in raw_prefix else re.sub(r"node_modules/[^\s'\"\\]*", "", t)


def norm_name(x):
    x = x.strip("'\"")
    x = re.sub(r"^:(!|\^|\(exclude\))", "", x)
    x = re.sub(r"^!", "", x).strip()
    return re.sub(r"^\./", "", x).rstrip("/*")


def covered(excluded, under_raw):
    """Every --under prefix is excluded (by itself or by a parent)."""
    ex = [e for e in excluded if e]
    return bool(under_raw) and all(any(u.rstrip("/") == e or u.rstrip("/").startswith(e + "/") for e in ex) for u in under_raw)


def code_path(p, roots, under):
    p = p.strip("'\"")
    if not p or p.startswith(":") or any(u.search(p) for u in under):
        return False
    r = "|".join(re.escape(x) for x in roots)
    return bool(re.match(r"^(\./)?(%s)(/|$)" % r, p) or re.search(r"/(%s)(/|$)" % r, p))


def classify(p, roots, under):
    """-> 'var' | 'outside' | 'ignored' | 'code' | 'file' | 'reach'"""
    p = p.strip("'\"")
    if "$" in p or "`" in p:
        return "var"
    if p.startswith("/") and any(m in p + ("" if p.endswith("/") else "/") for m in OUTSIDE_MARKERS):
        return "outside"
    if set(p.split("/")) & IGNORED_DIRS:
        return "ignored"
    if code_path(p, roots, under):
        return "code"
    if re.search(r"\.[A-Za-z0-9]{1,8}$", p):          # a single named file (or *.ext glob): cannot reach a directory of notes
        return "file"
    return "reach"


def segments(cmd):
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        toks = list(lex)
    except ValueError:
        toks = cmd.split()
    out, cur = [], []
    for t in toks:
        if t and set(t) <= set("();|&\n"):
            if cur:
                out.append(cur)
                cur = []
        else:
            cur.append(t)
    if cur:
        out.append(cur)
    return out


def search_args(seg):
    """-> dict(pats, paths, excludes, stdin_filter) for one simple command, or None when it is not a file search."""
    i = 0
    while i < len(seg) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", seg[i]):
        i += 1
    if i >= len(seg):
        return None
    prog = seg[i].rsplit("/", 1)[-1]
    rest = seg[i + 1:]
    git = False
    if prog == "git":
        j = 0
        while j < len(rest) and rest[j].startswith("-"):
            j += 2 if rest[j] in ("-C", "-c") else 1
        if j >= len(rest) or rest[j] != "grep":
            return None
        git, rest, prog = True, rest[j + 1:], "grep"
    elif prog not in SEARCHERS:
        return None
    pats, pos, after, excludes, recursive, k, in_paths = [], [], [], [], False, 0, False
    while k < len(rest):
        t = rest[k]
        k += 1
        if t in (">", ">>", "<", "2>", "&>") or re.fullmatch(r"\d?[<>]+", t):
            k += 1
            continue
        if t == "--":
            in_paths = True
            continue
        if in_paths:
            after.append(t)
        elif t.startswith("-") and t != "-":
            name = t.split("=", 1)[0]
            if re.fullmatch(r"-[A-Za-z]*[rR][A-Za-z]*", t) or name in ("--recursive", "--dereference-recursive"):
                recursive = True
            val = t.split("=", 1)[1] if "=" in t else (rest[k] if name in OPT_ARG and k < len(rest) else None)
            if name in ("--exclude", "--exclude-dir") and val:
                excludes.append(norm_name(val))
            if name in ("-g", "--glob", "--iglob") and val and val.startswith("!"):
                excludes.append(norm_name(val))
            if name in OPT_ARG and "=" not in t and k < len(rest):
                if name in PATTERN_OPT:
                    pats.append(rest[k])
                k += 1
            elif name in PATTERN_OPT and "=" in t:
                pats.append(t.split("=", 1)[1])
        else:
            pos.append(t)
    if not pats and pos:
        pats, pos = [pos[0]], pos[1:]
    paths = []
    for p in pos + after:
        if EXCL_PATHSPEC.match(p):
            excludes.append(norm_name(p))
        else:
            paths.append(p)
    stdin_filter = (not git) and prog in ("grep", "egrep", "fgrep") and not recursive and not paths
    return {"pats": " ".join(pats), "paths": paths, "excludes": excludes, "stdin_filter": stdin_filter}


def ticket_search(name, inp, terms, roots, under, under_raw):
    """-> (reason | None, unresolved: bool)"""
    low = [t.lower() for t in terms]
    hit = lambda s: any(t in s.lower() for t in low)
    if name == "Grep":
        if not hit(str(inp.get("pattern", ""))):
            return None, False
        glob = inp.get("glob") if isinstance(inp.get("glob"), str) else ""
        excl = []
        if glob.startswith("!"):
            excl = [norm_name(x) for x in re.split(r"[{},]", glob[1:]) if x and not x.startswith("*")]
        path = inp.get("path") if isinstance(inp.get("path"), str) and inp.get("path") else ""
        kind = classify(path, roots, under) if path else "reach"
        if kind == "var":
            return None, True
        if kind == "reach" and not covered(excl, under_raw):
            return "Grep for the ticket over a directory that can reach %s" % "/".join(under_raw), False
        return None, False
    if name == "Glob":
        pat = str(inp.get("pattern", ""))
        if not hit(pat):
            return None, False
        base = inp.get("path") if isinstance(inp.get("path"), str) else ""
        kind = classify(base, roots, under) if base else ("code" if code_path(pat, roots, under) else "reach")
        return ("Glob for the ticket that can reach %s" % "/".join(under_raw), False) if kind == "reach" else (None, False)
    if name == "Bash" and isinstance(inp.get("command"), str):
        unresolved = False
        for seg in segments(inp["command"]):
            r = search_args(seg)
            if not r or not hit(r["pats"]) or r["stdin_filter"]:
                continue
            kinds = [classify(p, roots, under) for p in r["paths"]]
            reach = (not r["paths"]) or "reach" in kinds
            if "var" in kinds and not reach:
                unresolved = True
                continue
            if reach and not covered(r["excludes"], under_raw):
                return "search for the ticket over a target that can reach %s: %s" % ("/".join(under_raw), " ".join(seg)[:100]), unresolved
        return None, unresolved
    return None, False


EVAL_DIR = "dt-runs"
EVAL_TOKEN = re.compile(r"[^\s'\"`;|&()<>=,]*%s[^\s'\"`;|&()<>=,]*" % EVAL_DIR)
WORKTREES = re.compile(r"\.claude/worktrees")
RETRO_BRANCH = re.compile(r"(?i)\b(?:fix|work|feat|chore|hotfix)/retro-\d")
GIT_LIST = re.compile(r"\bgit\s+(?:-C\s+\S+\s+)?(?:worktree\s+list\b|branch\b(?!\s+--show-current))")
ANSWER_KEY = re.compile(r"""(?:deliver-ticket/evals\b|(?:^|[\s'"=:(])\.{0,2}/?evals/|sample-tiers|\btruth\.json)""")


def expand_home(tok, home):
    for h in ("${HOME}", "$HOME", "~"):
        if tok.startswith(h):
            return home + tok[len(h):]
    return tok


def eval_leak(text, own_home):
    """-> reason string or None. Mentions of dt-runs/ outside the run's own home, or of the answer key."""
    import os
    home = os.path.expanduser("~")
    own = os.path.normpath(expand_home(own_home, home))
    for tok in EVAL_TOKEN.findall(text.replace("\\/", "/")):
        p = os.path.normpath(expand_home(tok, home))
        if p == own or p.startswith(own + os.sep):
            continue
        return "reads outside this run's home (%s): ...%s..." % (own_home, tok[:80])
    m = ANSWER_KEY.search(text)
    if m:
        return "touches the answer key (evals/): ...%s..." % text[max(0, m.start() - 8):m.end() + 14]
    m = WORKTREES.search(text)
    if m:
        return "reads a ticket worktree (.claude/worktrees/ holds finished tickets): ...%s..." % text[max(0, m.start() - 20):m.end() + 14]
    m = RETRO_BRANCH.search(text)
    if m:
        return "references a finished ticket's branch (<type>/retro-N): ...%s..." % text[max(0, m.start() - 8):m.end() + 14]
    m = GIT_LIST.search(text)
    if m:
        return "lists worktrees or branches (REVIEW, not invalid: the output shows other tickets' branches): ...%s..." % text[m.start():m.end() + 10]
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("transcript")
    ap.add_argument("--under", action="append", default=None)
    ap.add_argument("--ticket")
    ap.add_argument("--title", action="append", default=[])
    ap.add_argument("--code-root", action="append", default=None)
    ap.add_argument("--eval-run", default=None)
    a = ap.parse_args()
    under_raw = a.under or ["docs"]
    under = [prefix_regex(p) for p in under_raw]
    roots = a.code_root or DEFAULT_CODE_ROOTS
    terms = ([a.ticket] if a.ticket else []) + a.title
    try:
        rows = open(a.transcript).read().splitlines()
    except OSError as e:
        print("cannot read %s: %s" % (a.transcript, e), file=sys.stderr)
        return 2
    docs = []
    for line in rows:
        try:
            docs.append(json.loads(line))
        except ValueError:
            docs.append(None)
    bad = set()
    for d in docs:
        errored_ids(d, bad)
    n = skipped = unresolved_n = 0
    attempts = []
    for lineno, d in enumerate(docs, 1):
        if d is None:
            continue
        for cid, name, inp in calls(d):
            errored = cid in bad
            text = json.dumps(inp, ensure_ascii=False)
            why = []
            for raw, u in zip(under_raw, under):
                hay = under_text(text, raw)
                m = u.search(hay)
                if m:
                    why.append("touches %s: ...%s..." % (raw, hay[max(0, m.start() - 8):m.end() + 14]))
                    break
            if a.eval_run:
                leak = eval_leak(text, a.eval_run)
                if leak:
                    why.append(leak)
            if terms:
                r, unres = ticket_search(name, inp, terms, roots, under, under_raw)
                if unres:
                    unresolved_n += 1
                if r:
                    why.append(r)
            if errored:                      # did not run (tool unavailable, or blocked by a hook): never counted, but an attempt is shown
                skipped += 1
                if why:
                    attempts.append("line %d %s" % (lineno, name))
                continue
            if why:
                n += 1
                print("line %d  %-6s [%s] %s" % (lineno, name, "; ".join(why), text[:160]))
    if skipped:
        print("%d errored call(s) skipped (is_error)%s" % (skipped, "; would have been flagged if they had run (attempts, not counted): " + ", ".join(attempts) if attempts else ""))
    if unresolved_n:
        print("%d search(es) for the ticket with an unresolvable ($VAR) target, not listed" % unresolved_n)
    print("%d call(s) flagged" % n)
    return 1 if n else 0


if __name__ == "__main__":
    sys.exit(main())
