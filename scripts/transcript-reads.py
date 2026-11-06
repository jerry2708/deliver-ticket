#!/usr/bin/env python3
"""Check a Claude Code session transcript against the intake rule "repo notes are not searched for the ticket".

usage: transcript-reads.py <session.jsonl> [--under PREFIX ...] [--ticket ID [--title WORD ...]] [--code-root DIR ...]
  --under PREFIX   list every Read / Grep / Glob / Bash call that mentions the path, with or without a trailing slash
                   (default `docs`; a multi-segment prefix such as node_modules/next/dist/docs is matched as written)
  --ticket ID      also list every search (Grep, Glob, Bash grep / rg / ag / ack / git grep) that contains the ticket ID or a
                   --title word (case-insensitive) and is not restricted to code paths. Restricted = it names at least one path
                   and every named path is under a code root (--code-root, default apps packages src lib app server client
                   scripts) and none is under an --under prefix. `git grep ... -- ':!x'` only excludes, so it is NOT a restriction.
                   `git log --grep` and a grep that filters stdin are not file searches and are not listed.
It only reads the transcript (tool calls, never their results). Exit 0 = nothing found, 1 = at least one call listed (read the list:
technical docs by API / symbol and knowledge sources opened by path are allowed), 2 = bad input.
"""
import argparse
import json
import re
import shlex
import sys

DEFAULT_CODE_ROOTS = ["apps", "packages", "src", "lib", "app", "server", "client", "scripts"]
SEARCHERS = {"grep", "egrep", "fgrep", "rg", "ag", "ack"}
OPT_ARG = {"-e", "-f", "-m", "-A", "-B", "-C", "-d", "-D", "-g", "-t", "-T", "--include", "--exclude", "--exclude-dir",
           "--exclude-from", "--file", "--regexp", "--max-count", "--glob", "--iglob", "--type", "--type-not", "--max-depth"}
PATTERN_OPT = {"-e", "-f", "--regexp", "--file"}


def calls(obj):
    if isinstance(obj, dict):
        if obj.get("type") == "tool_use" and isinstance(obj.get("input"), dict):
            yield obj.get("name", "?"), obj["input"]
        for v in obj.values():
            yield from calls(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from calls(v)


def prefix_regex(p):
    p = p.strip().rstrip("/")
    if "/" in p:
        return re.compile(re.escape(p) + r"(?![\w-])")
    return re.compile(r"(?<![\w.-])" + re.escape(p) + r"(?![\w-])")


def code_path(p, roots, under):
    p = p.strip("'\"")
    if not p or p.startswith(":"):
        return False
    if any(u.search(p) for u in under):
        return False
    r = "|".join(re.escape(x) for x in roots)
    return bool(re.match(r"^(\./)?(%s)(/|$)" % r, p) or re.search(r"/(%s)(/|$)" % r, p))


def segments(cmd):
    """Split a shell command into [token list] per simple command (quotes respected; operators split)."""
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
                out.append(cur); cur = []
        else:
            cur.append(t)
    if cur:
        out.append(cur)
    return out


def search_args(seg):
    """-> (is_file_search, terms_text, paths, filters_stdin) for one simple command, or None."""
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
    pats, pos, after, recursive, k = [], [], [], False, 0
    in_paths = False
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
    paths = [p for p in (pos + after) if not re.match(r"^:(!|\^|\(exclude\))", p)]
    stdin_filter = (not git) and prog in ("grep", "egrep", "fgrep") and not recursive and not paths
    return True, " ".join(pats), paths, stdin_filter


def ticket_search(name, inp, terms, roots, under):
    """-> reason string if this call is a search for the ticket that is not restricted to code paths."""
    low = [t.lower() for t in terms]
    hit = lambda s: any(t in s.lower() for t in low)
    if name == "Grep":
        if not hit(str(inp.get("pattern", ""))):
            return None
        paths = [x for x in (inp.get("path"), inp.get("glob")) if isinstance(x, str) and x]
        ok = paths and all(code_path(p, roots, under) for p in paths)
        return None if ok else "Grep for the ticket, not restricted to code paths"
    if name == "Glob":
        pat = str(inp.get("pattern", ""))
        if not hit(pat):
            return None
        base = inp.get("path") if isinstance(inp.get("path"), str) else ""
        ok = (base and code_path(base, roots, under)) or code_path(pat, roots, under)
        return None if ok else "Glob for the ticket, not restricted to code paths"
    if name == "Bash" and isinstance(inp.get("command"), str):
        for seg in segments(inp["command"]):
            r = search_args(seg)
            if not r:
                continue
            _, text, paths, stdin_filter = r
            if not hit(text) or stdin_filter:
                continue
            if not (paths and all(code_path(p, roots, under) for p in paths)):
                return "search for the ticket, not restricted to code paths: %s" % " ".join(seg)[:100]
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("transcript")
    ap.add_argument("--under", action="append", default=None)
    ap.add_argument("--ticket")
    ap.add_argument("--title", action="append", default=[])
    ap.add_argument("--code-root", action="append", default=None)
    a = ap.parse_args()
    under_raw = a.under or ["docs"]
    under = [prefix_regex(p) for p in under_raw]
    roots = a.code_root or DEFAULT_CODE_ROOTS
    terms = ([a.ticket] if a.ticket else []) + a.title
    try:
        f = open(a.transcript)
    except OSError as e:
        print("cannot read %s: %s" % (a.transcript, e), file=sys.stderr)
        return 2
    n = 0
    for lineno, line in enumerate(f, 1):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        for name, inp in calls(d):
            text = json.dumps(inp, ensure_ascii=False)
            why = []
            for raw, u in zip(under_raw, under):
                hay = text if "node_modules" in raw else re.sub(r"node_modules/[^\s'\"\\]*", "", text)   # library docs are not repo notes
                m = u.search(hay)
                if m:
                    why.append("touches %s: ...%s..." % (raw, hay[max(0, m.start() - 8):m.end() + 14]))
                    break
            if terms:
                r = ticket_search(name, inp, terms, roots, under)
                if r:
                    why.append(r)
            if why:
                n += 1
                print("line %d  %-6s [%s] %s" % (lineno, name, "; ".join(why), text[:160]))
    print("%d call(s) flagged" % n)
    return 1 if n else 0


if __name__ == "__main__":
    sys.exit(main())
