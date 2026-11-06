#!/usr/bin/env python3
"""Final branch name of a ticket, from guard.json `branch_naming`. Used by stage 1b after the WorktreeCreate hook made the provisional
branch (type `work`, no slug), which is then renamed with `git -C <worktree> branch -m <old> <new>` before the first commit.

usage: branch-name.py <guard.json> <ID> <type> "<slug words>" [--repo <main checkout>]
  placeholders: {id} {id-lowercase} {type} {slug}. type = feat | fix | refactor | test | chore (any lowercase word is accepted).
  slug  = the words in lowercase ASCII (accents folded), joined with `-`, at most 5 words and 40 characters (cut at a word boundary);
          an empty slug leaves no trailing `-` or `/`.
Prints the name. Exit 0 ok; 2 bad input / unknown placeholder / not a valid branch name; with --repo: 3 the branch already exists
locally, 4 it exists as a remote-tracking ref (stop and ask the user).
"""
import json
import re
import subprocess
import sys
import unicodedata

KNOWN = {"id", "id-lowercase", "type", "slug"}


def slugify(words):
    t = unicodedata.normalize("NFKD", words.replace("đ", "d").replace("Đ", "D")).encode("ascii", "ignore").decode()
    ws = [w for w in re.split(r"[^a-z0-9]+", t.lower()) if w][:5]
    out = ""
    for w in ws:
        cand = w if not out else out + "-" + w
        if len(cand) > 40:
            break
        out = cand
    return out


def tidy(name):
    name = re.sub(r"/+", "/", name)
    name = name.replace("/-", "/")
    name = re.sub(r"^-+", "", name)
    return re.sub(r"[-_.]+$", "", name).rstrip("/")


def main(argv):
    repo = None
    if "--repo" in argv:
        i = argv.index("--repo")
        repo = argv[i + 1] if i + 1 < len(argv) else None
        argv = argv[:i] + argv[i + 2:]
    if len(argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    _, guard, tid, typ, words = argv
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", tid) or not re.fullmatch(r"[a-z][a-z-]{0,15}", typ):
        print("branch-name: bad ID or type", file=sys.stderr)
        return 2
    try:
        naming = json.load(open(guard)).get("branch_naming") or "feature/{id}-{slug}"
    except (OSError, ValueError) as e:
        print("branch-name: cannot read %s: %s" % (guard, e), file=sys.stderr)
        return 2
    unknown = set(re.findall(r"\{([^{}]*)\}", naming)) - KNOWN
    if unknown or re.search(r"[{}]", re.sub(r"\{(?:%s)\}" % "|".join(map(re.escape, KNOWN)), "", naming)):
        print("branch-name: branch_naming %r has unknown placeholder(s) %s (known: %s)" % (naming, sorted(unknown) or "(stray brace)", sorted(KNOWN)), file=sys.stderr)
        return 2
    name = (naming.replace("{id-lowercase}", tid.lower()).replace("{id}", tid)
            .replace("{type}", typ).replace("{slug}", slugify(words)))
    name = tidy(name)
    if subprocess.run(["git", "check-ref-format", "--branch", name], capture_output=True).returncode != 0:
        print("branch-name: %r is not a valid branch name" % name, file=sys.stderr)
        return 2
    if repo:
        if subprocess.run(["git", "-C", repo, "show-ref", "--verify", "-q", "refs/heads/" + name]).returncode == 0:
            print("branch-name: %s already exists locally" % name, file=sys.stderr)
            return 3
        refs = subprocess.run(["git", "-C", repo, "for-each-ref", "--format=%(refname)", "refs/remotes"], capture_output=True, text=True).stdout.split()
        if any(r.split("/", 3)[-1] == name for r in refs):
            print("branch-name: %s already exists as a remote-tracking ref" % name, file=sys.stderr)
            return 4
    print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
