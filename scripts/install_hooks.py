#!/usr/bin/env python3
"""Implementation of install-hooks.sh. See init.md step 3 for the contract.

  status                 exit 0 when every hook and permission rule is registered exactly, else 1 (lists what differs)
  diff                   print the exact change to the settings file (unified diff); writes nothing
  apply --confirmed      back up the file, write, re-read to verify; refuses without --confirmed
  uninstall [--confirmed]  remove exactly what apply added (hooks of this skill + the permission rules apply added);
                         without --confirmed only prints the diff. Restore alternative: cp a backup over the settings file
  selftest [--repo R]    part B of the hook self-test (registration + scripted hook checks); writes nothing real;
                         with --repo also checks the project-level WorktreeCreate hook of that repo

WorktreeCreate (and the UserPromptSubmit bind hook) are NOT registered at user level: a user-level WorktreeCreate hook replaces Claude Code's own worktree
creation in every repo (verified 2026-11-05: repos without delivery state lost the .worktreeinclude copy). It is
registered per initialised project in <repo>/.claude/settings.local.json (gitignored):
  project-status|project-diff --repo R        print / diff only
  project-apply --repo R --confirmed [--add-exclude]   back up (into the project's state dir, not into the repo), write, verify.
                         The file holds an absolute hook path, so it must be git-ignored: when `git check-ignore` says it is not,
                         project-apply refuses (exit 3) unless --add-exclude (after the user saw the exclude diff in project-diff and said yes)
                         adds `/.claude/settings.local.json` to <git-common-dir>/info/exclude (never the repo's .gitignore)
  project-uninstall --repo R [--confirmed]    remove exactly what project-apply added

The Bash sandbox is enabled per project, in the same file (a separate decision from the hooks; the user-level part - no unsandboxed
retry, denyWrite for the protected state - comes from `apply` and is required first):
  project-sandbox-status|project-sandbox-diff --repo R [--domains a,b] [--local-binding]
  project-sandbox-apply --repo R --confirmed [--domains a,b] [--local-binding] [--add-exclude]
  project-sandbox-off --repo R [--confirmed]  remove exactly what project-sandbox-apply added (manifest in the state dir); run it before
                         checking out v0.1 on `main`, whose `bash scripts/...` calls fail inside the sandbox
"""
import copy
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

SKILL = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
HOOKS = os.path.join(SKILL, "hooks")
SETTINGS = os.path.realpath(os.environ.get("DT_SETTINGS") or os.path.expanduser("~/.claude/settings.json"))
sys.path.insert(0, HOOKS)
import dtcore  # noqa: E402  (constants only at import time; PROTECTED_STATE is the one list of the protected state)
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import fixed_env  # noqa: E402  (C11e3: status prints the python3 / git the excluded scripts use)

BOOKKEEPING = ["session-map.sh", "pending-ticket.sh", "project-map-stale.sh", "git-rename.sh", "base-worktree.sh"]   # sandbox: excluded + allow rule: no prompt
SANDBOXED = ["verify-record.sh", "plan-hash.sh", "lock-trace.sh"]                                   # NOT excluded: runs inside the sandbox; allow rule only (no prompt)
GATES = ["ticket-state.sh", "guard-apply.sh", "git-push.sh", "approve-plan.sh", "git-commit.sh"]                                     # excluded + ask rule on the full path: the prompt is the user's yes
# The gate scripts' ask rules are USER level too: with the sandbox off (or in a project that never enabled it) nothing else would ask, and auto mode
# ran an excluded command without a prompt (probe V8 d4).
# An ask rule always beats an allow rule (docs, "Manage permissions": "rule specificity doesn't change the order"), so a broad `glab *` ask with narrow
# allows cannot work: the gh / glab writes are enumerated. Option-before-subcommand forms (-R / --repo) are listed too; see the README limits for
# what a prefix list misses. USER level (below), because the project sandbox block does not exist in a project without the sandbox - the case where
# nothing is sandboxed and, in auto mode, the classifier would otherwise decide. In default mode these commands prompt anyway.
CLI_ASK = (["glab " + w + " *" for w in ("api", "auth", "variable", "repo", "ci", "release", "-R", "--repo", "alias", "config", "token", "issue", "label",
                                         "snippet", "ssh-key", "gpg-key")] +
           ["glab mr " + w + " *" for w in ("update", "note", "close", "approve", "reopen", "checkout", "delete")] +
           ["gh " + w + " *" for w in ("api", "auth", "secret", "variable", "repo", "workflow", "run", "release", "-R", "--repo", "alias", "extension",
                                       "config", "issue", "gist", "label", "ssh-key", "gpg-key", "codespace")] +
           ["gh pr " + w + " *" for w in ("edit", "comment", "close", "review", "reopen", "checkout", "ready", "lock", "unlock")])
CLI_CREATE = ["glab mr create *", "gh pr create *"]            # their ask rules are the older `:*` spelling in ASK below
CLI_ALLOW = ["glab mr view *", "glab mr list *", "gh pr view *", "gh pr list *"]
ASK = (["Bash(git push:*)", "Bash(git branch -m:*)", "Bash(glab mr create:*)", "Bash(gh pr create:*)"] + ["Bash(%s *)" % os.path.join(SKILL, "scripts", g) for g in GATES] +
       ["Bash(%s)" % c for c in CLI_ASK])
DENY = ["Bash(glab mr merge:*)", "Bash(gh pr merge:*)", "Read(**/.env*)"]
# (event, matcher, script, timeout seconds, onFailure block?)
HOOK_SPECS = [
    ("PreToolUse", "Bash", "guard.sh", 10, True),
    ("PreToolUse", "Bash", "verify-on-push.sh", 1860, True),
    ("PreToolUse", "Edit|Write|NotebookEdit|MultiEdit", "worktree-guard.sh", 10, True),
    ("PreToolUse", "REPL", "code-mode.sh", 10, True),        # Code Mode's code tool: not supported, always denied (hooks/dtcore.py CODE_MODE_MSG)
    ("PreToolUse", "*", "mode-guard.sh", 10, True),          # C11h: every tool; a session bound to a ticket runs only in default mode (hooks/dtcore.py mode_pmode)
    ("PostToolUse", "EnterWorktree", "worktree-guard.sh", 10, False),
    ("SessionStart", "compact", "session-start.sh", 10, False),
    ("SessionStart", "startup|resume|clear", "session-record.sh", 10, False),     # C9a: <root>/starts/<session_id> = the start directory, first record wins
]
# registered per project (<repo>/.claude/settings.local.json), never at user level
PROJECT_SPECS = [("WorktreeCreate", None, "worktree-create.sh", 900, False),
                 ("UserPromptSubmit", None, "bind-session.sh", 10, False)]
RETIRED_USER = {"worktree-create.sh"}   # earlier versions registered these at user level; apply removes them


def state_root():
    return os.path.realpath(os.environ.get("DELIVER_TICKET_HOME") or os.path.expanduser("~/.local/share/deliver-ticket"))


def sandbox_deny():
    """User-level sandbox denyWrite entries: the protected state (hooks/dtcore.py protected_state), for every project key.
    Globs work for denyWrite on macOS (probe V7; on Linux only a trailing /** does). A deny always wins over an allowWrite."""
    r = state_root()
    home = os.path.realpath(os.path.expanduser("~"))
    xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
    git_cfg = [home + "/.gitconfig", home + "/.config/git/**"] + ([xdg + "/git/**"] if os.path.join(home, ".config") != xdg else [])
    # what the unsandboxed git-push.sh / gh / glab read and may execute from: ssh_config (ProxyCommand / LocalCommand / Match exec), .netrc, the gh / glab configs
    # (glab 1.124.0: an alias `!cmd` runs cmd; editor / browser run a command), see hooks/dtcore.py gitconfig_paths
    tools_cfg = [home + "/.ssh/**", home + "/.netrc", home + "/.config/gh/**", home + "/.config/glab-cli/**"]       # ~/.ssh/** (C9b): Include targets, config.d, keys too
    # the user's git config: git-push.sh / git-rename.sh run git unsandboxed and trust it (scripts/git_safe.py), so a sandboxed Bash must not write it
    # C9b: the Claude Code settings (hooks, permissions, sandbox) - changed only by this installer, run by the user unsandboxed
    return [r + "/" + p for p, _ in dtcore.PROTECTED_STATE] + git_cfg + tools_cfg + [home + "/.claude/settings*"]


# C11a: user-level file-tool rules (probe tool_* cases, Claude Code 2.1.311): an Edit(...) rule covers the Write tool too (a Write(...) allow does not), the
# sandbox denyWrite does not reach the file tools, //<abs> is an absolute path. Read: the skill and the whole state root; Edit: tickets/ and evidence/ only,
# minus the protected state. `root` / `skill` are for the probe.
# C11h: the other direction holds too - Claude Code merges Edit allow / deny rules into the Bash sandbox (docs "Sandboxing"; probe B1, c11h-probe-1). So the
# push record (VERIFY_RECORD, written by the sandboxed verify-record.sh) gets no Edit deny rule any more: that rule refused the script's own write (DRY-02). The
# hooks block the file tools on it (hooks/dtcore.py verify_record_target). retired_perm(): rules an earlier apply added that apply now removes and status flags.
VERIFY_RECORD = dtcore.VERIFY_RECORD_FILES


def retired_perm(root=None):
    r = "/" + (root or state_root())
    return (("deny", ["Edit(%s/*/evidence/*/%s)" % (r, n) for n in VERIFY_RECORD]),)


def file_allow(root=None, skill=SKILL):
    r = "/" + (root or state_root())
    return ["Read(/%s/**)" % skill, "Read(%s/**)" % r, "Edit(%s/*/tickets/**)" % r, "Edit(%s/*/evidence/**)" % r]


def file_deny(root=None):
    r = "/" + (root or state_root())
    return ["Edit(%s/%s%s)" % (r, p, "/**" if d else "") for p, d in dtcore.PROTECTED_STATE]


def perm_rules():
    """The user-level permission rules apply adds, per key."""
    return (("allow", file_allow()), ("ask", ASK), ("deny", DENY + file_deny()))


# Every subcommand is one or the other (a test keeps hooks/dtcore.py INSTALLER_WRITING equal to WRITING_COMMANDS): the hook blocks a Claude call of a
# writing one in every spelling - settings changes are made by the user in their own terminal, after reading `diff`.
READ_ONLY_COMMANDS = ("status", "diff", "selftest", "project-status", "project-diff", "project-sandbox-status", "project-sandbox-diff")
WRITING_COMMANDS = ("apply", "uninstall", "project-apply", "project-uninstall", "project-sandbox-apply", "project-sandbox-off")


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
    for ev in list(hooks):                       # retired registrations of ours (see RETIRED_USER)
        for g in hooks[ev]:
            g["hooks"] = [h for h in g.get("hooks", []) if not (ours(h) and os.path.basename(h["command"]) in RETIRED_USER)]
        hooks[ev] = [g for g in hooks[ev] if g.get("hooks")]
        if not hooks[ev]:
            del hooks[ev]
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
    om = load_manifest() or {"perm_added": {}}
    for key, rules in retired_perm():                # added by an earlier apply (manifest), no longer wanted (C11h): migrate away; a user's own copy stays
        ours_r = [r for r in rules if r in om["perm_added"].get(key, [])]
        if key in perms:
            perms[key] = [r for r in perms[key] if r not in ours_r]
    for key, rules in perm_rules():
        lst = perms.setdefault(key, [])
        for r in rules:
            if r not in lst:
                lst.append(r)
    # sandbox keys that matter whichever project turns the sandbox on: no unsandboxed retry (a user-level false holds over a
    # project true, docs), and the protected state is not writable by sandboxed Bash
    sb = new.setdefault("sandbox", {})
    sb["allowUnsandboxedCommands"] = False
    dw = sb.setdefault("filesystem", {}).setdefault("denyWrite", [])
    for e in sandbox_deny():
        if e not in dw:
            dw.append(e)
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
    m = old_manifest or {"perm_added": {"allow": [], "ask": [], "deny": []}, "perm_keys_created": [],
                         "permissions_created": False, "hooks_created": False, "events_created": []}
    m["perm_added"].setdefault("allow", [])          # a manifest from before C11a has no allow rules
    for key, rules in retired_perm():                # apply removes them (desired), so uninstall has nothing of them to remove
        m["perm_added"][key] = [r for r in m["perm_added"].get(key, []) if r not in rules]
    perms = cur.get("permissions")
    if old_manifest is None:
        m["permissions_created"] = perms is None
        m["hooks_created"] = "hooks" not in cur
    for key, rules in perm_rules():
        have = (perms or {}).get(key)
        if have is None and key not in m["perm_keys_created"]:
            m["perm_keys_created"].append(key)
        for r in rules:
            if r not in (have or []) and r not in m["perm_added"][key]:
                m["perm_added"][key].append(r)
    if "sandbox" not in m:
        sb = cur.get("sandbox")
        fs = (sb or {}).get("filesystem")
        have = (fs or {}).get("denyWrite")
        m["sandbox"] = {"created": sb is None, "fs_created": fs is None, "dw_created": have is None,
                        "aud_prev": (sb or {}).get("allowUnsandboxedCommands", "__absent__"),
                        "deny_added": [e for e in sandbox_deny() if e not in (have or [])]}
    else:
        have = ((cur.get("sandbox") or {}).get("filesystem") or {}).get("denyWrite") or []
        for e in sandbox_deny():
            if e not in have and e not in m["sandbox"]["deny_added"]:
                m["sandbox"]["deny_added"].append(e)
    for ev, *_ in HOOK_SPECS:
        if ev not in cur.get("hooks", {}) and ev not in m["events_created"]:
            m["events_created"].append(ev)
    m["events_created"] = [e for e in m["events_created"] if e in {ev for ev, *_ in HOOK_SPECS}]
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
    for key, rules in perm_rules():
        drop = rules if m is None else m["perm_added"].get(key, [])
        if key in perms:
            perms[key] = [r for r in perms[key] if r not in drop]
            if not perms[key] and (m is None or key in m["perm_keys_created"]):
                del perms[key]
    if "permissions" in new and not new["permissions"] and (m is None or m["permissions_created"]):
        del new["permissions"]
    sb = new.get("sandbox")
    if isinstance(sb, dict):
        ms = (m or {}).get("sandbox")
        drop = ms["deny_added"] if ms else sandbox_deny()
        fs = sb.get("filesystem")
        if isinstance(fs, dict) and "denyWrite" in fs:
            fs["denyWrite"] = [e for e in fs["denyWrite"] if e not in drop]
            if not fs["denyWrite"] and (ms is None or ms["dw_created"]):
                del fs["denyWrite"]
            if not fs and (ms is None or ms["fs_created"]):
                del sb["filesystem"]
        if ms:
            if ms["aud_prev"] == "__absent__":
                sb.pop("allowUnsandboxedCommands", None)
            else:
                sb["allowUnsandboxedCommands"] = ms["aud_prev"]
        elif sb.get("allowUnsandboxedCommands") is False:
            del sb["allowUnsandboxedCommands"]
        if not sb and (ms is None or ms["created"]):
            del new["sandbox"]
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
    for ev, groups in hooks.items():
        for g in groups:
            for h in g.get("hooks", []):
                if ours(h) and os.path.basename(h["command"]) in RETIRED_USER:
                    out.append("retired: %s %s must not be registered at user level (project level only); run apply" % (ev, os.path.basename(h["command"])))
    perms = cur.get("permissions", {})
    for key, rules in perm_rules():
        for r in rules:
            if r not in perms.get(key, []):
                out.append("missing permission %s: %s" % (key, r))
    om = load_manifest() or {"perm_added": {}}
    for key, rules in retired_perm():
        for r in rules:
            if r in perms.get(key, []) and r in om["perm_added"].get(key, []):
                out.append("retired permission %s: %s (it also denies the sandboxed verify-record.sh its own write); run apply" % (key, r))
    sb = cur.get("sandbox") if isinstance(cur.get("sandbox"), dict) else {}
    if sb.get("allowUnsandboxedCommands") is not False:
        out.append("sandbox.allowUnsandboxedCommands must be false (is %r)" % (sb.get("allowUnsandboxedCommands", "unset"),))
    have = ((sb.get("filesystem") or {}).get("denyWrite")) or []
    for e in sandbox_deny():
        if e not in have:
            out.append("missing sandbox.filesystem.denyWrite: %s" % e)
    return out


def cmd_status():
    print("excluded scripts use: " + fixed_env.describe())
    p = problems(load())
    if not p:
        print("ok: all %d hooks and %d permission rules registered, sandbox.allowUnsandboxedCommands false and %d denyWrite entries, in %s"
              % (len(HOOK_SPECS), sum(len(r) for _, r in perm_rules()), len(sandbox_deny()), SETTINGS))
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
    print("\nbackup apply will make: %s.bak-deliver-ticket-<YYYYMMDD-HHMMSS> (timestamp = time of apply)\n"
          "manifest apply will write: %s" % (SETTINGS, MANIFEST))
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
    mf = build_manifest(cur, load_manifest())      # read the old manifest BEFORE open(..., "w") truncates it
    with open(MANIFEST, "w") as f:
        json.dump(mf, f, indent=2)
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
    left = [x for x in problems(load()) if not x.startswith(("missing", "sandbox."))]
    print("removed; backup: %s%s" % (bak, "" if not left else "  WARNING leftovers: %s" % left))
    return 0



# ---- project level: WorktreeCreate + UserPromptSubmit (bind-session) in <repo>/.claude/settings.local.json ------------------------------------------------
def parse_repo(args):
    rest, repo, i = [], None, 0
    while i < len(args):
        if args[i] == "--repo" and i + 1 < len(args):
            repo = os.path.realpath(args[i + 1]); i += 2
        else:
            rest.append(args[i]); i += 1
    if not repo:
        raise SystemExit("need --repo <main checkout of the project>")
    top = subprocess.run(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                         capture_output=True, text=True)
    if top.returncode != 0:
        raise SystemExit("not a git repo: %s" % repo)
    common = top.stdout.strip()
    if not common.endswith("/.git") or not os.path.isdir(common):
        raise SystemExit("the git dir of %s is %s, not <main checkout>/.git (--separate-git-dir or a gitfile): not supported by this skill" % (repo, common))
    main = common[:-5]
    if os.path.realpath(main) != repo:
        raise SystemExit("--repo must be the main checkout (%s), not %s" % (main, repo))
    return rest, repo


def project_paths(repo):
    home = os.path.realpath(os.environ.get("DELIVER_TICKET_HOME") or os.path.expanduser("~/.local/share/deliver-ticket"))
    key = subprocess.run(["bash", "-c", '. "%s/lib.sh"; dt_key "%s"' % (HOOKS, repo)], capture_output=True, text=True).stdout.strip()
    state = os.path.join(home, key)
    return (os.path.join(repo, ".claude", "settings.local.json"), state,
            os.path.join(state, "worktree-hook-manifest.json"))


EXCLUDE_LINE = "/.claude/settings.local.json"


def settings_state(repo):
    """-> ('ignored'|'not-ignored'|'tracked', exclude file path)."""
    common = subprocess.run(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True).stdout.strip()
    excl = os.path.join(common, "info", "exclude")
    rel = ".claude/settings.local.json"
    if subprocess.run(["git", "-C", repo, "ls-files", "--error-unmatch", rel], capture_output=True).returncode == 0:
        return "tracked", excl
    ign = subprocess.run(["git", "-C", repo, "check-ignore", "-q", rel]).returncode == 0
    return ("ignored" if ign else "not-ignored"), excl


def exclude_diff(excl):
    old = open(excl).read() if os.path.exists(excl) else ""
    new = old + ("" if not old or old.endswith("\n") else "\n") + EXCLUDE_LINE + "\n"
    return "".join(difflib.unified_diff(old.splitlines(True), new.splitlines(True), "a/" + excl, "b/" + excl)), new


def project_load(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        d = json.load(f)
    if not isinstance(d, dict):
        raise SystemExit("settings file is not a JSON object: %s" % path)
    return d


# C11b: code edits in a ticket worktree need no prompt (the plan lock and the other hooks still decide), but an ask rule (ask beats allow) keeps a prompt on the
# shared base worktree (stage 4, base-worktree.sh) and, per worktree, on what configures Claude Code, git, MCP servers, git hooks, the editor, CI or submodules, and on agent
# instruction files and npm config at any depth (`*` = one path segment, probe tool_wt_star_one_segment).
WT_ASK = (".claude/**", ".git", ".git/**", ".mcp.json", ".husky/**", ".vscode/**", ".github/**", ".gitmodules")      # .github: CI runs with repo secrets on push
WT_ASK_ANY_DEPTH = ("CLAUDE.md", "CLAUDE.local.md", "AGENTS.md", "GEMINI.md", ".cursorrules", ".npmrc")


def project_rules(repo):
    wt = "/" + os.path.join(repo, ".claude", "worktrees")
    return (("allow", ["Edit(%s/**)" % wt]), ("ask", ["Edit(%s/_base/**)" % wt] + ["Edit(%s/*/%s)" % (wt, p) for p in WT_ASK] +
                                                   ["Edit(%s/*/**/%s)" % (wt, n) for n in WT_ASK_ANY_DEPTH]))


def project_desired(cur, repo):
    new = copy.deepcopy(cur)
    perms = new.setdefault("permissions", {})
    for key, rules in project_rules(repo):
        lst = perms.setdefault(key, [])
        lst += [r for r in rules if r not in lst]
    hooks = new.setdefault("hooks", {})
    for ev, matcher, script, timeout, block in PROJECT_SPECS:
        groups = hooks.setdefault(ev, [])
        want = entry(script, timeout, block)
        target = next((g for g in groups if g.get("matcher") == matcher), None)
        if target is None:
            groups.append({"hooks": [want]} if matcher is None else {"matcher": matcher, "hooks": [want]})
        else:
            lst = target.setdefault("hooks", [])
            lst[:] = [h for h in lst if not (ours(h) and os.path.basename(h["command"]) == script)] + [want]
    return new


def project_problems(cur, repo):
    out = []
    for ev, matcher, script, timeout, block in PROJECT_SPECS:
        want = entry(script, timeout, block)
        found = [h for g in cur.get("hooks", {}).get(ev, []) if g.get("matcher") == matcher
                 for h in g.get("hooks", []) if ours(h) and os.path.basename(h["command"]) == script]
        if not found:
            out.append("missing: %s %s" % (ev, script))
        elif found[0] != want or len(found) > 1:
            out.append("differs: %s %s: have %s, want %s" % (ev, script, found, want))
    perms = cur.get("permissions") if isinstance(cur.get("permissions"), dict) else {}
    for key, rules in project_rules(repo):
        out += ["missing permission %s: %s" % (key, r) for r in rules if r not in perms.get(key, [])]
    return out


def project_removed(cur, manifest, repo):
    new = copy.deepcopy(cur)
    perms = new.get("permissions", {})
    for key, rules in project_rules(repo):
        drop = rules if manifest is None else manifest.get("perm_added", {}).get(key, [])
        if key in perms:
            perms[key] = [r for r in perms[key] if r not in drop]
            if not perms[key] and (manifest is None or key in manifest.get("perm_keys_created", [])):
                del perms[key]
    if "permissions" in new and not new["permissions"] and (manifest is None or manifest.get("permissions_created")):
        del new["permissions"]
    hooks = new.get("hooks", {})
    for ev in list(hooks):
        for g in hooks[ev]:
            g["hooks"] = [h for h in g.get("hooks", []) if not ours(h)]
        hooks[ev] = [g for g in hooks[ev] if g.get("hooks")]
        if not hooks[ev] and (manifest is None or ev in manifest.get("events_created", [])):
            del hooks[ev]
    if "hooks" in new and not new["hooks"] and (manifest is None or manifest.get("hooks_created")):
        del new["hooks"]
    return new


def project_write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".settings-")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    if os.path.exists(path):
        shutil.copymode(path, tmp)
    os.replace(tmp, path)


def project_backup(path, state):
    if not os.path.exists(path):
        return None
    os.makedirs(os.path.join(state, "backups"), exist_ok=True)
    bak = os.path.join(state, "backups", "settings.local.json.bak-deliver-ticket-%s" % time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(path, bak)
    return bak


def cmd_project(cmd, args):
    rest, repo = parse_repo(args)
    path, state, mpath = project_paths(repo)
    cur = project_load(path)
    if cmd == "project-status":
        p = project_problems(cur, repo)
        print("ok: %s and the worktree Edit rules registered in %s" % (", ".join(e for e, *_ in PROJECT_SPECS), path) if not p else "not installed in %s:\n  %s" % (path, "\n  ".join(p)))
        return 1 if p else 0
    if cmd == "project-diff":
        new = project_desired(cur, repo)
        if dump(cur) == dump(new) and os.path.exists(path):
            print("no change: already installed"); return 0
        sys.stdout.writelines(difflib.unified_diff((dump(cur) if os.path.exists(path) else "").splitlines(True),
                                                   dump(new).splitlines(True), "a/" + path, "b/" + path))
        st, excl = settings_state(repo)
        if st == "tracked":
            print("\nNOT REGISTERABLE: %s is tracked by git; it would commit a machine-specific absolute hook path" % path)
        elif st == "not-ignored":
            print("\n%s is NOT git-ignored (check-ignore). The hook path is absolute and machine-specific, so project-apply also needs this change (local, never committed):" % path)
            sys.stdout.write(exclude_diff(excl)[0])
        else:
            print("\n%s is git-ignored (check-ignore): no exclude change needed" % path)
        print("\nbackup project-apply will make: %s/backups/settings.local.json.bak-deliver-ticket-<YYYYMMDD-HHMMSS>\n"
              "(in the state dir, not in the repo)\nmanifest project-apply will write: %s" % (state, mpath))
        return 0
    if cmd == "project-apply":
        if "--confirmed" not in rest or set(rest) - {"--confirmed", "--add-exclude"}:
            print("project-apply needs --confirmed (and optionally --add-exclude), only after the user saw `project-diff` and said yes in this conversation", file=sys.stderr)
            return 2
        if not os.path.isfile(os.path.join(state, "guard.json")):
            print("no guard.json in %s: initialise the project first (init writes the state before any hook)" % state, file=sys.stderr)
            return 2
        st, excl = settings_state(repo)
        if st == "tracked":
            print("%s is tracked by git: not registering a machine-specific hook path there" % path, file=sys.stderr)
            return 3
        if st == "not-ignored":
            if "--add-exclude" not in rest:
                print("%s is NOT git-ignored. Nothing written. Show `project-diff` (it includes the exclude change), and only after the user's yes "
                      "run project-apply --confirmed --add-exclude; declined = do not register the hook." % path, file=sys.stderr)
                return 3
            text = exclude_diff(excl)[1]
            os.makedirs(os.path.dirname(excl), exist_ok=True)
            with open(excl, "w") as f:
                f.write(text)
            if settings_state(repo)[0] != "ignored":
                print("added %s to %s but git still does not ignore the file; not registering" % (EXCLUDE_LINE, excl), file=sys.stderr)
                return 3
            print("added %s to %s" % (EXCLUDE_LINE, excl))
        new = project_desired(cur, repo)
        if dump(cur) == dump(new) and os.path.exists(path):
            print("already installed, nothing written"); return 0
        bak = project_backup(path, state)
        os.makedirs(state, exist_ok=True)
        try:
            old_m = json.load(open(mpath))
        except (OSError, ValueError):
            old_m = None
        om = old_m or {}
        events = sorted(set(om.get("events_created", [])) |
                        {ev for ev, *_ in PROJECT_SPECS if ev not in cur.get("hooks", {})})
        # the rules this apply adds beyond what was there (a manifest from before C11b has none): project-uninstall removes exactly these
        perms = cur.get("permissions") if isinstance(cur.get("permissions"), dict) else {}
        added = {k: list(om.get("perm_added", {}).get(k, [])) for k, _ in project_rules(repo)}
        for k, rules in project_rules(repo):
            added[k] += [r for r in rules if r not in perms.get(k, []) and r not in added[k]]
        keys_created = sorted(set(om.get("perm_keys_created", [])) | {k for k, _ in project_rules(repo) if k not in perms})
        with open(mpath, "w") as f:
            json.dump({"settings_created": om.get("settings_created", not os.path.exists(path)),
                       "hooks_created": om.get("hooks_created", "hooks" not in cur),
                       "events_created": events,
                       "permissions_created": om.get("permissions_created", "permissions" not in cur),
                       "perm_added": added, "perm_keys_created": keys_created}, f, indent=2)
        project_write(path, dump(new))
        if project_problems(project_load(path), repo):
            print("written file does not verify - restore from %s" % bak, file=sys.stderr); return 1
        print("written %s; backup: %s" % (path, bak))
        return 0
    if cmd == "project-uninstall":
        try:
            m = json.load(open(mpath))
        except (OSError, ValueError):
            m = None
        new = project_removed(cur, m, repo)
        if dump(cur) == dump(new):
            print("nothing to remove"); return 0
        if rest != ["--confirmed"]:
            sys.stdout.writelines(difflib.unified_diff(dump(cur).splitlines(True), dump(new).splitlines(True), "a/" + path, "b/" + path))
            print("\n(dry run; add --confirmed to write)"); return 0
        bak = project_backup(path, state)
        project_write(path, dump(new))
        if os.path.exists(mpath):
            os.replace(mpath, mpath + ".removed")
        print("removed; backup: %s" % bak)
        return 0
    return 2


# ---- project level: the Bash sandbox in <repo>/.claude/settings.local.json ---------------------------------------------------------------------------
ABSENT = "__absent__"
DOMAIN_RE = re.compile(r"[A-Za-z0-9*][A-Za-z0-9*.-]*")


def git_common(repo):
    """realpath of the repo's git common dir (the ref store lives there; parse_repo already refused a separate git dir)."""
    r = subprocess.run(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("cannot read the git common dir of %s" % repo)
    return os.path.realpath(r.stdout.strip())


# C11: the git ref store under the common dir. With these denied a sandboxed command cannot move a branch (commit, merge, rebase, reset, update-ref,
# fetch . x:<branch>, checkout -B ... - probe refs_*); commits go through the excluded gate git-commit.sh, renames through git-rename.sh, pushes through git-push.sh.
REF_STORE = ("refs/**", "packed-refs", "logs/refs/**")
# C11: git files that the unsandboxed scripts' git (base-worktree checkout, git-commit, git-push) and your own git in the main checkout read: a filter / diff /
# merge driver named in info/attributes, or defined in a config file, would run there. On 2.1.325 the three config files are EPERM from Claude Code's own git
# protection already, info/attributes was writable (probe gitcfg_*); denied here so neither depends on that. Not info/** (setup-exclude.sh writes info/exclude),
# not hooks/** (EPERM from Claude Code itself, probe gitdir_hooks_*), not objects/ or worktrees/*/HEAD (git add and checkout need them).
GIT_READ = ("config", "config.worktree", "worktrees/*/config.worktree", "info/attributes")


def sandbox_plan(repo, state, domains, local_binding, common=None):
    sk = os.path.join(SKILL, "scripts")
    book, gate, boxed = [os.path.join(sk, x) for x in BOOKKEEPING], [os.path.join(sk, x) for x in GATES], [os.path.join(sk, x) for x in SANDBOXED]
    # C11c1: autoAllowBashIfSandboxed is the default on 2.1.311; from 2.1.325 it is false (changelog, docs/plan.md C11 record), and then every sandboxed command would prompt
    sets = [(("sandbox", "enabled"), True), (("sandbox", "failIfUnavailable"), True), (("sandbox", "autoAllowBashIfSandboxed"), True)]
    if local_binding:
        sets.append((("sandbox", "network", "allowLocalBinding"), True))
    adds = [(("sandbox", "excludedCommands"), [p + " *" for p in book + gate] + CLI_CREATE + CLI_ASK + CLI_ALLOW),
            (("sandbox", "filesystem", "allowWrite"), [os.path.join(state, "evidence"), os.path.join(repo, ".claude", "worktrees")]),
            # C9b: the project's own settings and every ticket worktree's (a deny wins over the worktrees allowWrite; a glob works on macOS only, V7c)
            (("sandbox", "filesystem", "denyWrite"), [os.path.join(repo, ".claude", "settings.json"), os.path.join(repo, ".claude", "settings.local.json"),
                                                     os.path.join(repo, ".claude", "worktrees", "*", ".claude", "settings*.json")] +
                                                    ([os.path.join(common, x) for x in REF_STORE + GIT_READ] if common else [])),
            (("sandbox", "network", "allowedDomains"), list(domains)),
            (("permissions", "allow"), ["Bash(%s *)" % p for p in book + boxed] + ["Bash(%s)" % c for c in CLI_ALLOW]),
            (("permissions", "ask"), ["Bash(%s *)" % p for p in gate] + ["Bash(%s)" % c for c in CLI_ASK])]
    return sets, adds


def _node(d, path, m=None):
    """The dict at `path`; creates missing ones (recorded in the manifest) when m is given, else returns None if absent."""
    for i, k in enumerate(path):
        if not isinstance(d.get(k), dict):
            if m is None:
                return None
            d[k] = {}
            key = "/".join(path[:i + 1])
            if key not in m["created_dicts"]:
                m["created_dicts"].append(key)
        d = d[k]
    return d


def sandbox_desired(cur, sets, adds, m):
    new = copy.deepcopy(cur)
    for path, val in sets:
        node = _node(new, path[:-1], m)
        m["set_prev"].setdefault("/".join(path), node.get(path[-1], ABSENT))
        node[path[-1]] = val
    for path, items in adds:
        node = _node(new, path[:-1], m)
        k = "/".join(path)
        if k != "sandbox/network/allowedDomains" and isinstance(node.get(path[-1]), list):
            for old in [x for x in m["added"].get(k, []) if x not in items]:      # added by an earlier apply, no longer in the plan: migrate away
                node[path[-1]] = [x for x in node[path[-1]] if x != old]
                m["added"][k].remove(old)
        if not isinstance(node.get(path[-1]), list):
            node[path[-1]] = []
            if k not in m["created_lists"]:
                m["created_lists"].append(k)
        for it in items:
            if it not in node[path[-1]]:
                node[path[-1]].append(it)
                m["added"].setdefault(k, [])
                if it not in m["added"][k]:
                    m["added"][k].append(it)
    return new


def sandbox_removed(cur, m):
    new = copy.deepcopy(cur)
    for k in sorted(set(m["added"]) | set(m["created_lists"])):
        items = m["added"].get(k, [])
        path = k.split("/")
        node = _node(new, path[:-1])
        if node is not None and isinstance(node.get(path[-1]), list):
            node[path[-1]] = [x for x in node[path[-1]] if x not in items]
            if not node[path[-1]] and k in m["created_lists"]:
                del node[path[-1]]
    for k, prev in m["set_prev"].items():
        path = k.split("/")
        node = _node(new, path[:-1])
        if node is not None:
            if prev == ABSENT:
                node.pop(path[-1], None)
            else:
                node[path[-1]] = prev
    for k in sorted(m["created_dicts"], key=lambda x: -len(x.split("/"))):
        path = k.split("/")
        parent = _node(new, path[:-1])
        if parent is not None and parent.get(path[-1]) == {}:
            del parent[path[-1]]
    return new


def sandbox_problems(cur, plan_sets, plan_adds):
    out = []
    for path, val in plan_sets:
        n = _node(cur, path[:-1])
        if n is None or n.get(path[-1]) != val:
            out.append("%s must be %r" % (".".join(path), val))
    for path, items in plan_adds:
        n = _node(cur, path[:-1])
        have = (n or {}).get(path[-1]) or []
        out += ["missing %s: %s" % (".".join(path), it) for it in items if it not in have]
    return out


def user_sandbox_missing():
    return [x for x in problems(load()) if x.startswith(("sandbox.", "missing sandbox."))]


def cmd_sandbox(cmd, args):
    rest, repo = parse_repo(args)
    domains, local_binding, flags, i = [], False, [], 0
    while i < len(rest):
        if rest[i] == "--domains" and i + 1 < len(rest):
            domains = [x for x in rest[i + 1].split(",") if x]
            i += 2
        else:
            if rest[i] == "--local-binding":
                local_binding = True
            flags.append(rest[i]); i += 1
    bad = [d for d in domains if not DOMAIN_RE.fullmatch(d)]
    if bad:
        print("not a host name: %s" % ", ".join(bad), file=sys.stderr); return 2
    path, state, _ = project_paths(repo)
    spath = os.path.join(state, "sandbox-manifest.json")
    cur = project_load(path)
    try:
        om = json.load(open(spath))
    except (OSError, ValueError):
        om = None
    fresh = lambda: copy.deepcopy(om) if om else {"set_prev": {}, "added": {}, "created_dicts": [], "created_lists": [], "settings_created": not os.path.exists(path)}
    if cmd == "project-sandbox-status":
        if om is None:
            print("sandbox: off (no sandbox manifest in %s)" % state); return 1
        sets, adds = sandbox_plan(repo, state, [], "sandbox/network/allowLocalBinding" in om["set_prev"], git_common(repo))
        p = sandbox_problems(cur, sets, adds) + [x for k, its in om["added"].items() if k == "sandbox/network/allowedDomains"
                                                  for x in ["missing domain: %s" % d for d in its if d not in (_node(cur, ["sandbox", "network"]) or {}).get("allowedDomains", [])]]
        print("sandbox: on in %s" % path if not p else "sandbox: DRIFT in %s:\n  %s" % (path, "\n  ".join(p)))
        return 1 if p else 0
    if cmd == "project-sandbox-off":
        if om is None:
            print("no sandbox manifest in %s: nothing to remove (the sandbox was not enabled by project-sandbox-apply)" % state); return 1
        new = sandbox_removed(cur, om)
        if dump(cur) == dump(new):
            print("nothing to remove"); return 0
        if flags != ["--confirmed"]:
            sys.stdout.writelines(difflib.unified_diff(dump(cur).splitlines(True), dump(new).splitlines(True), "a/" + path, "b/" + path))
            print("\n(dry run; add --confirmed to write)"); return 0
        bak = project_backup(path, state)
        project_write(path, dump(new))
        os.replace(spath, spath + ".removed")
        print("sandbox removed; backup: %s\nThe project can be checked out on v0.1 (main) now." % bak)
        return 0
    sets, adds = sandbox_plan(repo, state, domains, local_binding, git_common(repo))
    m = fresh()
    new = sandbox_desired(cur, sets, adds, m)
    if cmd == "project-sandbox-diff":
        if dump(cur) == dump(new) and os.path.exists(path):
            print("no change: already enabled"); return 0
        sys.stdout.writelines(difflib.unified_diff((dump(cur) if os.path.exists(path) else "").splitlines(True), dump(new).splitlines(True), "a/" + path, "b/" + path))
        print("\nnetwork: %s" % (("allowed domains " + ", ".join(domains)) if domains else "NO allowed domains (no network from sandboxed commands); pass --domains"))
        miss = user_sandbox_missing()
        if miss:
            print("\nNOT APPLICABLE YET: the user-level sandbox settings are missing (run install-hooks.sh diff / apply first):\n  " + "\n  ".join(miss))
        st, excl = settings_state(repo)
        if st == "tracked":
            print("\nNOT REGISTERABLE: %s is tracked by git" % path)
        elif st == "not-ignored":
            print("\n%s is NOT git-ignored; project-sandbox-apply also needs (local, never committed):" % path)
            sys.stdout.write(exclude_diff(excl)[0])
        print("\nbackup: %s/backups/settings.local.json.bak-deliver-ticket-<ts>; manifest: %s; creates %s/evidence if missing" % (state, spath, state))
        return 0
    if cmd == "project-sandbox-apply":
        if "--confirmed" not in flags or set(flags) - {"--confirmed", "--add-exclude", "--local-binding"}:
            print("project-sandbox-apply needs --confirmed, only after the user saw project-sandbox-diff and said yes in this conversation", file=sys.stderr); return 2
        miss = user_sandbox_missing()
        if miss:
            print("refused: the user-level sandbox settings are missing (a project-level sandbox without them leaves the unsandboxed retry open):\n  " + "\n  ".join(miss), file=sys.stderr); return 3
        if not os.path.isfile(os.path.join(state, "guard.json")):
            print("no guard.json in %s: initialise the project first" % state, file=sys.stderr); return 2
        st, excl = settings_state(repo)
        if st == "tracked":
            print("%s is tracked by git: not writing machine-specific absolute paths there" % path, file=sys.stderr); return 3
        if st == "not-ignored":
            if "--add-exclude" not in flags:
                print("%s is NOT git-ignored. Nothing written. Show project-sandbox-diff and, after the user's yes, run again with --add-exclude." % path, file=sys.stderr); return 3
            os.makedirs(os.path.dirname(excl), exist_ok=True)
            with open(excl, "w") as f:
                f.write(exclude_diff(excl)[1])
            if settings_state(repo)[0] != "ignored":
                print("added the exclude line but git still does not ignore the file; not writing", file=sys.stderr); return 3
        if dump(cur) == dump(new) and os.path.exists(path):
            print("already enabled, nothing written"); return 0
        os.makedirs(os.path.join(state, "evidence"), exist_ok=True)
        bak = project_backup(path, state)
        with open(spath, "w") as f:                    # m was built from the old manifest above, before this open() truncates it
            json.dump(m, f, indent=2)
        project_write(path, dump(new))
        left = sandbox_problems(project_load(path), sets, adds)
        if left:
            print("written file does not verify (%s) - restore from %s" % ("; ".join(left), bak), file=sys.stderr); return 1
        print("written %s; backup: %s%s" % (path, bak, "" if domains else "\nnote: no --domains, sandboxed commands have no network"))
        return 0
    return 2



def run_hook(script, payload, env, cwd):
    t = time.time()
    p = subprocess.run([os.path.join(HOOKS, script)], input=payload, capture_output=True, text=True, env=env, cwd=cwd, timeout=60)
    return p.returncode, p.stdout, p.stderr, time.time() - t


def cmd_selftest(args=()):
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
    for key, rules in perm_rules():
        for r in rules:
            check(r in cur.get("permissions", {}).get(key, []), "permission %s %s" % (key, r))
    retired = [p for p in problems(cur) if p.startswith("retired")]
    check(not retired, "no WorktreeCreate hook of ours at user level (it replaces Claude Code's worktree creation in every repo)")
    if args:
        rest, repo = parse_repo(list(args))
        path, state, mpath = project_paths(repo)
        pp = project_problems(project_load(path), repo)
        check(not pp, "project-level hooks (WorktreeCreate, UserPromptSubmit) and worktree Edit rules registered in %s%s" % (path, "" if not pp else ": " + "; ".join(pp)))

    base = os.path.join(os.environ.get("TMPDIR", "/tmp"), "deliver-ticket-selftest")  # reused, never deleted
    os.makedirs(base, exist_ok=True)
    env = dict(os.environ, DELIVER_TICKET_HOME=os.path.join(base, "state"))
    nostate = os.path.join(base, "nostate")
    repo = os.path.join(base, "repo")
    for d in (nostate, repo):
        # a leftover .git directory is not proof of a repository (an emptied one made every state-dependent check below fail); `git init` is idempotent and repairs it
        if not (os.path.isdir(d) and subprocess.run(["git", "-C", d, "rev-parse", "--git-dir"], capture_output=True).returncode == 0):
            os.makedirs(d, exist_ok=True)
            subprocess.run(["git", "init", "-q", d], check=True)
    pre = json.dumps({"session_id": "st", "cwd": nostate, "hook_event_name": "PreToolUse", "permission_mode": "default", "tool_name": "Bash",
                      "tool_input": {"command": "git push -f origin main; cat .env"}})
    # (4a) repo without state: every hook passes, fast
    for script in ("guard.sh", "verify-on-push.sh", "worktree-guard.sh", "mode-guard.sh", "session-start.sh"):
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

    def bash_payload(c, mode="default"):
        return json.dumps({"session_id": "st", "cwd": repo, "hook_event_name": "PreToolUse", "permission_mode": mode, "tool_name": "Bash",
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
    # (6) C11h: a session bound to a ticket (st -> ST-1 above) runs only in default mode
    rc, _, _, _ = run_hook("mode-guard.sh", bash_payload("git status", "auto"), env, repo)
    check(rc == 2, "mode-guard.sh: a bound session in auto mode is blocked")
    rc, _, _, _ = run_hook("mode-guard.sh", bash_payload("git status"), env, repo)
    check(rc == 0, "mode-guard.sh: a bound session in default mode passes")
    print("selftest B: %s" % ("PASS" if not fails else "FAIL (%d)" % len(fails)))
    return 1 if fails else 0


def main():
    a = sys.argv[1:]
    cmds = READ_ONLY_COMMANDS + WRITING_COMMANDS
    if not a or a[0] not in cmds:
        print(__doc__)
        return 2
    if a[0].startswith("project-sandbox-"):
        return cmd_sandbox(a[0], a[1:])
    if a[0].startswith("project-"):
        return cmd_project(a[0], a[1:])
    if a[0] == "selftest":
        if a[1:] and a[1] != "--repo":
            print(__doc__); return 2
        return cmd_selftest(a[1:])
    return {"status": cmd_status, "diff": cmd_diff}.get(a[0], lambda: cmd_uninstall(a[1:]) if a[0] == "uninstall" else cmd_apply(a[1:]))()


if __name__ == "__main__":
    sys.exit(main())
