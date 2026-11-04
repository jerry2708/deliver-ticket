#!/usr/bin/env python3
"""Implementation of install-hooks.sh. See init.md step 3 for the contract.

  status                 exit 0 when every hook and permission rule is registered exactly, else 1 (lists what differs)
  diff                   print the exact change to the settings file (unified diff); writes nothing
  apply --confirmed      back up the file, write, re-read to verify; refuses without --confirmed
  uninstall [--confirmed]  remove exactly what apply added (hooks of this skill + the permission rules apply added);
                         without --confirmed only prints the diff. Restore alternative: cp a backup over the settings file
  selftest               part B of the hook self-test (registration + scripted hook checks); writes nothing real
"""
import copy
import difflib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

SKILL = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
HOOKS = os.path.join(SKILL, "hooks")
SETTINGS = os.path.realpath(os.environ.get("DT_SETTINGS") or os.path.expanduser("~/.claude/settings.json"))

ASK = ["Bash(git push:*)", "Bash(glab mr create:*)", "Bash(gh pr create:*)"]
DENY = ["Bash(glab mr merge:*)", "Bash(gh pr merge:*)", "Read(**/.env*)"]
# (event, matcher, script, timeout seconds, onFailure block?)
HOOK_SPECS = [
    ("PreToolUse", "Bash", "guard.sh", 10, True),
    ("PreToolUse", "Bash", "verify-on-push.sh", 1860, True),
    ("PreToolUse", "Edit|Write|NotebookEdit|MultiEdit", "worktree-guard.sh", 10, True),
    ("PostToolUse", "EnterWorktree", "worktree-guard.sh", 10, False),
    ("WorktreeCreate", None, "worktree-create.sh", 900, False),
    ("SessionStart", "compact", "session-start.sh", 10, False),
]


def entry(script, timeout, block):
    e = {"type": "command", "command": os.path.join(HOOKS, script), "timeout": timeout}
    if block:
        e["onFailure"] = "block"
    return e


def load():
    if not os.path.exists(SETTINGS):
        return {}
    with open(SETTINGS) as f:
        d = json.load(f)
    if not isinstance(d, dict):
        raise SystemExit("settings file is not a JSON object: %s" % SETTINGS)
    return d


def ours(h):
    return isinstance(h, dict) and str(h.get("command", "")).startswith(HOOKS + os.sep)


def desired(cur):
    """Return a copy of settings with exactly our hooks (replacing stale ours) and rules."""
    new = copy.deepcopy(cur)
    hooks = new.setdefault("hooks", {})
    for ev, matcher, script, timeout, block in HOOK_SPECS:
        groups = hooks.setdefault(ev, [])
        # drop a stale copy of this very script under this event+matcher, keep everything else
        target = None
        for g in groups:
            if g.get("matcher") == matcher:
                target = g
                break
        want = entry(script, timeout, block)
        if target is None:
            g = {"hooks": [want]}
            if matcher is not None:
                g = {"matcher": matcher, "hooks": [want]}
            groups.append(g)
        else:
            lst = target.setdefault("hooks", [])
            lst[:] = [h for h in lst if not (ours(h) and os.path.basename(h["command"]) == script)]
            lst.append(want)
    perms = new.setdefault("permissions", {})
    for key, rules in (("ask", ASK), ("deny", DENY)):
        lst = perms.setdefault(key, [])
        for r in rules:
            if r not in lst:
                lst.append(r)
    return new


MANIFEST = SETTINGS + ".deliver-ticket-manifest.json"


def load_manifest():
    try:
        with open(MANIFEST) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def build_manifest(cur, old_manifest):
    """What apply adds to `cur` beyond what was already there (so uninstall removes only that)."""
    m = old_manifest or {"perm_added": {"ask": [], "deny": []}, "perm_keys_created": [],
                         "permissions_created": False, "hooks_created": False, "events_created": []}
    perms = cur.get("permissions")
    if old_manifest is None:
        m["permissions_created"] = perms is None
        m["hooks_created"] = "hooks" not in cur
    for key, rules in (("ask", ASK), ("deny", DENY)):
        have = (perms or {}).get(key)
        if have is None and key not in m["perm_keys_created"]:
            m["perm_keys_created"].append(key)
        for r in rules:
            if r not in (have or []) and r not in m["perm_added"][key]:
                m["perm_added"][key].append(r)
    for ev, *_ in HOOK_SPECS:
        if ev not in cur.get("hooks", {}) and ev not in m["events_created"]:
            m["events_created"].append(ev)
    return m


def removed(cur, m):
    """Copy of settings without this skill's hooks and the rules the manifest says apply added."""
    new = copy.deepcopy(cur)
    hooks = new.get("hooks", {})
    for ev in list(hooks):
        for g in hooks[ev]:
            g["hooks"] = [h for h in g.get("hooks", []) if not ours(h)]
        hooks[ev] = [g for g in hooks[ev] if g.get("hooks")]
        if not hooks[ev] and (m is None or ev in m["events_created"]):
            del hooks[ev]
    if "hooks" in new and not new["hooks"] and (m is None or m["hooks_created"]):
        del new["hooks"]
    perms = new.get("permissions", {})
    for key, rules in (("ask", ASK), ("deny", DENY)):
        drop = rules if m is None else m["perm_added"].get(key, [])
        if key in perms:
            perms[key] = [r for r in perms[key] if r not in drop]
            if not perms[key] and (m is None or key in m["perm_keys_created"]):
                del perms[key]
    if "permissions" in new and not new["permissions"] and (m is None or m["permissions_created"]):
        del new["permissions"]
    return new


def dump(d):
    return json.dumps(d, indent=2, ensure_ascii=False) + "\n"


def problems(cur):
    out = []
    hooks = cur.get("hooks", {})
    for ev, matcher, script, timeout, block in HOOK_SPECS:
        want = entry(script, timeout, block)
        found = [h for g in hooks.get(ev, []) if g.get("matcher") == matcher
                 for h in g.get("hooks", []) if ours(h) and os.path.basename(h["command"]) == script]
        if not found:
            out.append("missing: %s [%s] %s" % (ev, matcher, script))
        elif found[0] != want or len(found) > 1:
            out.append("differs: %s [%s] %s: have %s, want %s" % (ev, matcher, script, found, want))
    perms = cur.get("permissions", {})
    for key, rules in (("ask", ASK), ("deny", DENY)):
        for r in rules:
            if r not in perms.get(key, []):
                out.append("missing permission %s: %s" % (key, r))
    return out


def cmd_status():
    p = problems(load())
    if not p:
        print("ok: all %d hooks and %d permission rules registered in %s" % (len(HOOK_SPECS), len(ASK) + len(DENY), SETTINGS))
        return 0
    print("not installed in %s:" % SETTINGS)
    for x in p:
        print("  " + x)
    return 1


def cmd_diff():
    cur = load()
    old = dump(cur) if os.path.exists(SETTINGS) else ""
    new = dump(desired(cur))
    if old == new:
        print("no change: already installed")
        return 0
    sys.stdout.writelines(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
                                               "a/" + SETTINGS, "b/" + SETTINGS))
    return 0


def cmd_apply(args):
    if args != ["--confirmed"]:
        print("apply needs --confirmed, only after the user saw `diff` and said yes in this conversation", file=sys.stderr)
        return 2
    cur = load()
    new = desired(cur)
    if dump(cur) == dump(new) and os.path.exists(SETTINGS):
        print("already installed, nothing written")
        return 0
    bak = None
    if os.path.exists(SETTINGS):
        bak = "%s.bak-deliver-ticket-%s" % (SETTINGS, time.strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(SETTINGS, bak)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(SETTINGS), prefix=".settings-")
    with os.fdopen(fd, "w") as f:
        f.write(dump(new))
    if os.path.exists(SETTINGS):
        shutil.copymode(SETTINGS, tmp)
    os.replace(tmp, SETTINGS)
    with open(MANIFEST, "w") as f:
        json.dump(build_manifest(cur, load_manifest()), f, indent=2)
    if problems(load()):
        print("written file does not verify - restore from %s" % bak, file=sys.stderr)
        return 1
    print("written %s; backup: %s" % (SETTINGS, bak))
    return 0


def cmd_uninstall(args):
    cur = load()
    m = load_manifest()
    new = removed(cur, m)
    old_s, new_s = dump(cur), dump(new)
    if m is None:
        print("note: no manifest at %s - removing every rule this skill could have added" % MANIFEST, file=sys.stderr)
    if args != ["--confirmed"]:
        if old_s == new_s:
            print("nothing to remove")
        else:
            sys.stdout.writelines(difflib.unified_diff(old_s.splitlines(True), new_s.splitlines(True),
                                                       "a/" + SETTINGS, "b/" + SETTINGS))
            print("\n(dry run; add --confirmed to write)")
        return 0
    if old_s == new_s:
        print("nothing to remove")
        return 0
    bak = "%s.bak-deliver-ticket-%s" % (SETTINGS, time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(SETTINGS, bak)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(SETTINGS), prefix=".settings-")
    with os.fdopen(fd, "w") as f:
        f.write(new_s)
    shutil.copymode(SETTINGS, tmp)
    os.replace(tmp, SETTINGS)
    if os.path.exists(MANIFEST):
        os.replace(MANIFEST, MANIFEST + ".removed")
    left = [x for x in problems(load()) if not x.startswith("missing")]
    print("removed; backup: %s%s" % (bak, "" if not left else "  WARNING leftovers: %s" % left))
    return 0


def run_hook(script, payload, env, cwd):
    t = time.time()
    p = subprocess.run([os.path.join(HOOKS, script)], input=payload, capture_output=True, text=True, env=env, cwd=cwd, timeout=60)
    return p.returncode, p.stdout, p.stderr, time.time() - t


def cmd_selftest():
    fails = []

    def check(ok, what):
        print(("ok   " if ok else "FAIL ") + what)
        if not ok:
            fails.append(what)

    cur = load()
    # (3) registration: every entry has timeout; guard entries have onFailure block; scripts exist + executable
    for ev, matcher, script, timeout, block in HOOK_SPECS:
        found = [h for g in cur.get("hooks", {}).get(ev, []) if g.get("matcher") == matcher
                 for h in g.get("hooks", []) if ours(h) and os.path.basename(h["command"]) == script]
        good = bool(found) and "timeout" in found[0] and (found[0].get("onFailure") == "block") == block \
            and os.access(found[0]["command"], os.X_OK)
        check(good, "registered with timeout%s: %s %s" % (" + onFailure block" if block else "", ev, script))
    for key, rules in (("ask", ASK), ("deny", DENY)):
        for r in rules:
            check(r in cur.get("permissions", {}).get(key, []), "permission %s %s" % (key, r))

    base = os.path.join(os.environ.get("TMPDIR", "/tmp"), "deliver-ticket-selftest")  # reused, never deleted
    os.makedirs(base, exist_ok=True)
    env = dict(os.environ, DELIVER_TICKET_HOME=os.path.join(base, "state"))
    nostate = os.path.join(base, "nostate")
    repo = os.path.join(base, "repo")
    for d in (nostate, repo):
        if not os.path.isdir(os.path.join(d, ".git")):
            os.makedirs(d, exist_ok=True)
            subprocess.run(["git", "init", "-q", d], check=True)
    pre = json.dumps({"session_id": "st", "cwd": nostate, "hook_event_name": "PreToolUse", "tool_name": "Bash",
                      "tool_input": {"command": "git push -f origin main; cat .env"}})
    # (4a) repo without state: every hook passes, fast
    for script in ("guard.sh", "verify-on-push.sh", "worktree-guard.sh", "session-start.sh"):
        rc, out, err, dt = run_hook(script, pre, env, nostate)
        check(rc == 0 and not err and dt < 2, "%s in a repo without state: exit 0 in %.2fs" % (script, dt))
    # (4b) repo with state: malformed payload blocks, a forced push blocks, an ordinary command passes
    key_out = subprocess.run(["bash", "-c", '. "%s/lib.sh"; dt_key "%s"' % (HOOKS, repo)], capture_output=True, text=True).stdout
    sdir = os.path.join(base, "state", key_out)
    os.makedirs(sdir, exist_ok=True)
    with open(os.path.join(sdir, "guard.json"), "w") as f:
        json.dump({"version": 1, "project_key": key_out, "repo_root": os.path.realpath(repo), "base_branch": "main",
                   "remotes": {"push": None, "allowed": ["mirror"], "forbidden": ["origin"]},
                   "verify": {"lint": None, "test": None, "build": None, "on_push": [], "timeout_sec": 30},
                   "env_files": [], "install": None, "ports": {"vars": [], "base": 3100, "step": 10},
                   "allowlist_extra": []}, f)

    def bash_payload(c):
        return json.dumps({"session_id": "st", "cwd": repo, "hook_event_name": "PreToolUse", "tool_name": "Bash",
                           "tool_input": {"command": c}})
    rc, _, _, _ = run_hook("guard.sh", "not json", env, repo)
    check(rc == 2, "guard.sh: malformed payload in a repo with state blocks")
    rc, _, err, _ = run_hook("guard.sh", bash_payload("echo DELIVER_TICKET_SELFTEST; git push -f mirror x"), env, repo)
    check(rc == 2, "guard.sh: forced push blocked")
    rc, _, _, _ = run_hook("guard.sh", bash_payload("cat .env"), env, repo)
    check(rc == 2, "guard.sh: cat .env blocked")
    rc, _, _, _ = run_hook("guard.sh", bash_payload("git status"), env, repo)
    check(rc == 0, "guard.sh: git status passes")
    # (5) session-start returns the re-orientation text for a known session
    os.makedirs(os.path.join(base, "state", "sessions"), exist_ok=True)
    os.makedirs(os.path.join(sdir, "tickets"), exist_ok=True)
    with open(os.path.join(base, "state", "sessions", "st"), "w") as f:
        f.write("ticket=ST-1\nproject=%s\n" % key_out)
    with open(os.path.join(sdir, "tickets", "ST-1.md"), "w") as f:
        f.write("stage: 3\nnext: read stages/3-build.md\n")
    rc, out, _, _ = run_hook("session-start.sh", json.dumps({"session_id": "st", "cwd": repo, "source": "compact",
                                                              "hook_event_name": "SessionStart"}), env, repo)
    check(rc == 0 and "ST-1" in out and "stage 3" in out, "session-start.sh: re-orientation text for a known session")
    print("selftest B: %s" % ("PASS" if not fails else "FAIL (%d)" % len(fails)))
    return 1 if fails else 0


def main():
    a = sys.argv[1:]
    if not a or a[0] not in ("status", "diff", "apply", "selftest", "uninstall"):
        print(__doc__)
        return 2
    return {"status": cmd_status, "diff": cmd_diff, "selftest": cmd_selftest}.get(a[0], lambda: cmd_uninstall(a[1:]) if a[0] == "uninstall" else cmd_apply(a[1:]))()


if __name__ == "__main__":
    sys.exit(main())
