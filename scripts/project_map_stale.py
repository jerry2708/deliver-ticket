#!/usr/bin/env python3
"""Freshness of the sections of <state>/project.md, with git as the clock (see scripts/project-map-stale.sh).

A section carries `checked: <sha> · <date> · watch: <glob>, <glob>`. Only STRUCTURAL changes since <sha> make it
stale: files added / deleted / renamed (A/D/R) under its watch globs, plus the profile rules below. Modified-only
files are ignored. The profile rules are read from `profiles/*.md` (machine-readable `dt:<key>: v1, v2` lines), so
a new ecosystem needs a new profile file, not a script edit:
  dt:config-files     any change (also M) to a file with this basename, under a watch glob, marks the section stale
  dt:json-keys        `file=key1,key2`: a modified JSON file counts only if one of those keys changed (package.json=scripts)
  dt:lockfiles        a change of which lockfile TYPES exist (package-manager switch) proposes an init re-run; a modified lockfile is nothing
  dt:workspace-files  any change to such a file (pnpm-workspace.yaml ...) proposes an init re-run
  dt:app-roots        a new <root>/<name>/ directory (new top-level app or package) proposes an init re-run
The clock is the base ref passed in (guard.json base_branch, the local ref worktrees are created from); nothing is fetched.
"""
import argparse
import datetime
import fnmatch
import json
import os
import re
import subprocess
import sys

PROFILES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "profiles")
RULE_KEYS = ("config-files", "json-keys", "lockfiles", "workspace-files", "app-roots")
SEP = "·"


def run(repo, *args):
    r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("git %s: %s" % (" ".join(args), r.stderr.strip()))
    return r.stdout


def glob_re(g):
    g = g.strip()
    if g.endswith("/"):
        g += "**"
    out, i = "", 0
    while i < len(g):
        if g.startswith("**/", i):
            out += "(?:.*/)?"; i += 3
        elif g.startswith("**", i):
            out += ".*"; i += 2
        elif g[i] == "*":
            out += "[^/]*"; i += 1
        elif g[i] == "?":
            out += "[^/]"; i += 1
        else:
            out += re.escape(g[i]); i += 1
    return re.compile("^" + out + "$")


def load_rules(profiles_dir):
    """Union of the `dt:<key>: a, b` lines of every profile -> {key: [values]}."""
    rules = {k: [] for k in RULE_KEYS}
    try:
        names = sorted(os.listdir(profiles_dir))
    except OSError:
        return rules
    for n in names:
        if not n.endswith(".md"):
            continue
        for l in open(os.path.join(profiles_dir, n)):
            m = re.match(r"^dt:([a-z-]+):\s*(.*?)\s*$", l)
            if m and m.group(1) in rules:
                rules[m.group(1)] += [v.strip() for v in m.group(2).split(",") if v.strip()]
    return rules


def base_match(path, patterns):
    return any(fnmatch.fnmatch(os.path.basename(path), pt) for pt in patterns)


def json_keys_changed(repo, sha, ref, path, rules):
    """True if path is a json-keys file whose listed keys differ between sha and ref (or cannot be read)."""
    for spec in rules["json-keys"]:
        name, _, keys = spec.partition("=")
        if os.path.basename(path) != name.strip():
            continue
        try:
            old = json.loads(run(repo, "show", "%s:%s" % (sha, path)))
            new = json.loads(run(repo, "show", "%s:%s" % (ref, path)))
        except (RuntimeError, ValueError):
            return True
        return any(old.get(k) != new.get(k) for k in re.split(r"[|;+]", keys) if k)
    return None      # not a json-keys file


def parse(text):
    """-> list of dicts {title, start, end, checked_line, sha, date, watch, stale_line}; lines are 0-based."""
    lines = text.split("\n")
    heads = [i for i, l in enumerate(lines) if l.startswith("## ")]
    secs = []
    for n, h in enumerate(heads):
        end = heads[n + 1] if n + 1 < len(heads) else len(lines)
        s = {"title": lines[h][3:].strip(), "start": h, "end": end, "checked_line": None, "stale_line": None,
             "sha": None, "date": None, "watch": []}
        for j in range(h + 1, end):
            m = re.match(r"^checked:\s*(\S+)\s*(?:%s\s*(\S+))?\s*(?:%s\s*watch:\s*(.*))?$" % (SEP, SEP), lines[j])
            if m and s["checked_line"] is None:
                s["checked_line"], s["sha"], s["date"] = j, m.group(1), m.group(2)
                s["watch"] = [w.strip() for w in (m.group(3) or "").split(",") if w.strip()]
            elif re.match(r"^stale:", lines[j]) and s["stale_line"] is None:
                s["stale_line"] = j
        secs.append(s)
    return lines, secs


def changes(repo, sha, ref):
    """-> list of (status letter, path, old_path|None) from git diff --name-status -M sha..ref."""
    out = []
    for l in run(repo, "diff", "--name-status", "-M", "%s..%s" % (sha, ref)).splitlines():
        p = l.split("\t")
        st = p[0][0]
        if st == "R" or st == "C":
            out.append(("R" if st == "R" else "A", p[2], p[1]))
        else:
            out.append((st, p[1], None))
    return out


def new_top_level_apps(repo, sha, ch, rules):
    found = []
    for st, path, _ in ch:
        seg = path.split("/")
        if st == "A" and len(seg) >= 3 and seg[0] in rules["app-roots"]:
            d = "/".join(seg[:2])
            if d not in found and not run(repo, "ls-tree", "-r", "--name-only", sha, "--", d).strip():
                found.append(d)
    return found


def lockfile_switch(repo, sha, ref, ch, rules):
    lock = rules["lockfiles"]
    if not any(st in "ADR" and base_match(p, lock) for st, p, _ in ch):
        return None
    def types(rev):
        return {os.path.basename(f) for f in run(repo, "ls-tree", "-r", "--name-only", rev).splitlines()
                if base_match(f, lock)}
    a, b = types(sha), types(ref)
    return "lockfile type changed (package manager switch): %s -> %s" % (", ".join(sorted(a)) or "none", ", ".join(sorted(b)) or "none") if a != b else None


def evaluate(lines, secs, repo, ref, rules):
    """-> (results [(title, 'fresh'|'stale', reason)], propose_init reason|None)."""
    res, propose, cache = [], None, {}
    for s in secs:
        if s["checked_line"] is None:
            continue
        marked = s["stale_line"] is not None and re.match(r"^stale:\s*yes", lines[s["stale_line"]])
        sha = s["sha"]
        try:
            run(repo, "cat-file", "-e", sha + "^{commit}")
        except RuntimeError:
            res.append((s["title"], "stale", "checked sha %s not found in the repo" % sha)); continue
        if sha not in cache:
            ch = changes(repo, sha, ref)
            why = None
            ws = [p for st, p, o in ch if base_match(p, rules["workspace-files"])]
            if ws:
                why = "workspace config changed: %s" % ", ".join(sorted(set(ws)))
            if not why:
                why = lockfile_switch(repo, sha, ref, ch, rules)
            if not why:
                apps = new_top_level_apps(repo, sha, ch, rules)
                why = "new top-level app/package: %s" % ", ".join(apps) if apps else None
            cache[sha] = (ch, why)
        ch, why = cache[sha]
        propose = propose or why
        rx = [glob_re(w) for w in s["watch"]]
        hit = None
        for st, path, old in ch:
            paths = [path] + ([old] if old else [])
            if not any(r.match(p) for r in rx for p in paths):
                continue
            if st in "ADR":
                hit = "%s %s" % (st, path); break
            if base_match(path, rules["config-files"]):
                hit = "%s %s (config file)" % (st, path); break
            if json_keys_changed(repo, sha, ref, path, rules):
                hit = "%s %s (%s changed)" % (st, path, next(sp.partition("=")[2] for sp in rules["json-keys"] if sp.partition("=")[0].strip() == os.path.basename(path))); break
        if hit:
            res.append((s["title"], "stale", hit))
        elif marked:
            res.append((s["title"], "stale", "marked stale earlier, not rescanned yet"))
        else:
            res.append((s["title"], "fresh", "no structural change under %s" % (", ".join(s["watch"]) or "(no watch globs)")))
    return res, propose


def short(repo, ref):
    return run(repo, "rev-parse", "--short=10", ref).strip()


def main():
    ap = argparse.ArgumentParser(prog="project-map-stale.sh")
    ap.add_argument("cmd", choices=["check", "apply", "mark-checked"])
    ap.add_argument("project_md")
    ap.add_argument("sections", nargs="*", help="mark-checked: section titles")
    ap.add_argument("--guard", help="guard.json: repo_root and base_branch are read from it")
    ap.add_argument("--repo")
    ap.add_argument("--ref")
    ap.add_argument("--profiles", default=PROFILES_DIR, help="directory of profile files (default: ../profiles)")
    a = ap.parse_args()
    repo, ref = a.repo, a.ref
    if a.guard:
        g = json.load(open(a.guard))
        repo, ref = repo or g["repo_root"], ref or g["base_branch"]
    if not (repo and ref):
        print("need --guard, or --repo and --ref", file=sys.stderr); return 2
    if a.cmd in ("apply", "mark-checked"):
        # these two WRITE the file and run unprompted and unsandboxed: only <state>/project.md of the project whose guard.json was passed
        if not a.guard:
            print("%s writes the file: pass --guard <state>/guard.json" % a.cmd, file=sys.stderr); return 2
        want = os.path.join(os.path.realpath(os.path.dirname(os.path.realpath(a.guard))), "project.md")
        if os.path.realpath(a.project_md) != want:
            print("%s writes only <state>/project.md next to the guard.json given (%s), not %s" % (a.cmd, want, a.project_md), file=sys.stderr); return 2
    text = open(a.project_md).read()
    lines, secs = parse(text)
    if not any(s["checked_line"] is not None for s in secs):
        print("no `checked:` line in %s" % a.project_md, file=sys.stderr); return 2
    try:
        head = short(repo, ref)
        today = datetime.date.today().isoformat()
        if a.cmd == "mark-checked":
            want = set(a.sections)
            missing = want - {s["title"] for s in secs}
            if not want or missing:
                print("unknown/missing section(s): %s" % ", ".join(sorted(missing or {"(none given)"})), file=sys.stderr); return 2
            for s in reversed(secs):
                if s["title"] in want and s["checked_line"] is not None:
                    watch = ", ".join(s["watch"])
                    lines[s["checked_line"]] = "checked: %s %s %s %s watch: %s" % (head, SEP, today, SEP, watch)
                    if s["stale_line"] is not None:
                        lines[s["stale_line"]] = "stale: no"
                    else:
                        lines.insert(s["checked_line"] + 1, "stale: no")
            open(a.project_md, "w").write("\n".join(lines))
            print("marked checked at %s: %s" % (head, ", ".join(sorted(want))))
            return 0
        rules = load_rules(a.profiles)
        note = None if any(rules.values()) else "no profile rules found in %s: only added/deleted/renamed files count" % os.path.normpath(a.profiles)
        res, propose = evaluate(lines, secs, repo, ref, rules)
        if a.cmd == "apply":
            by = {t: (st, why) for t, st, why in res}
            for s in reversed(secs):
                if s["title"] not in by:
                    continue
                st = by[s["title"]][0]
                if st == "fresh":
                    watch = ", ".join(s["watch"])
                    lines[s["checked_line"]] = "checked: %s %s %s %s watch: %s" % (head, SEP, today, SEP, watch)
                    if s["stale_line"] is not None:
                        lines[s["stale_line"]] = "stale: no"
                else:
                    new = "stale: yes (%s)" % by[s["title"]][1]
                    if s["stale_line"] is not None:
                        lines[s["stale_line"]] = new
                    else:
                        lines.insert(s["checked_line"] + 1, new)
            open(a.project_md, "w").write("\n".join(lines))
        for t, st, why in res:
            print("%s %s :: %s" % (st, t, why))
        if note:
            print("note :: " + note)
        if propose:
            print("propose-init :: %s" % propose)
        return 1 if (propose or any(st == "stale" for _, st, _ in res)) else 0
    except RuntimeError as e:
        print(str(e), file=sys.stderr); return 2


if __name__ == "__main__":
    sys.exit(main())
