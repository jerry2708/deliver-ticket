#!/bin/bash
# apply + uninstall on a copy of a settings file must restore it byte for byte.
# usage: tests/run-installer.sh <new-or-empty scratch dir> [settings file to copy; default ~/.claude/settings.json]
set -u
SK="$(cd "$(dirname "$0")/.." && pwd)"
[ "$(cd "$SK" && pwd -P)" = "$(cd "$HOME/.claude/skills/deliver-ticket" 2>/dev/null && pwd -P)" ] && echo "warning: this suite tests the LIVE checkout $SK - build and test in the dev clone (docs/plan.md, dev-copy process)" >&2
D="${1:?scratch dir (must be empty or new)}"
SRC="${2:-$HOME/.claude/settings.json}"
mkdir -p "$D"; [ -z "$(ls -A "$D")" ] || { echo "scratch dir not empty" >&2; exit 1; }
cp "$SRC" "$D/s.json"
export DT_SETTINGS="$D/s.json"
fail=0
# the source may already have this skill installed: start the round trip from a copy without it
"$SK/scripts/install-hooks.sh" uninstall --confirmed >/dev/null 2>&1
cp "$D/s.json" "$D/orig.json"
"$SK/scripts/install-hooks.sh" apply --confirmed >/dev/null 2>&1 && echo "ok apply" || { fail=1; echo "FAIL apply"; }
"$SK/scripts/install-hooks.sh" status >/dev/null 2>&1 && echo "ok status after apply" || { fail=1; echo "FAIL status after apply"; }
cmp -s "$D/orig.json" "$D/s.json" && { fail=1; echo "FAIL apply changed nothing"; }
"$SK/scripts/install-hooks.sh" uninstall --confirmed >/dev/null 2>&1 && echo "ok uninstall" || { fail=1; echo "FAIL uninstall"; }
cmp -s "$D/orig.json" "$D/s.json" && echo "ok byte-identical after uninstall" || { fail=1; echo "FAIL not restored"; }
"$SK/scripts/install-hooks.sh" status >/dev/null 2>&1 && { fail=1; echo "FAIL status says installed after uninstall"; } || echo "ok status: not installed"
# --- WorktreeCreate is not a user-level hook: a legacy user-level registration is removed by apply
python3 -I - "$D/legacy.json" "$SK" <<'PY'
import json, os, sys
out, sk = sys.argv[1], sys.argv[2]
json.dump({"hooks": {"WorktreeCreate": [{"hooks": [{"type": "command", "command": os.path.join(sk, "hooks", "worktree-create.sh"), "timeout": 900}]}],
                     "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/other-hook.sh"}]}]}}, open(out, "w"), indent=2)
PY
DT_SETTINGS="$D/legacy.json" "$SK/scripts/install-hooks.sh" status >/dev/null 2>&1 && { fail=1; echo "FAIL status should flag the retired user-level WorktreeCreate"; } || echo "ok status flags the retired registration"
DT_SETTINGS="$D/legacy.json" "$SK/scripts/install-hooks.sh" apply --confirmed >/dev/null 2>&1 && echo "ok apply on legacy" || { fail=1; echo "FAIL apply on legacy"; }
grep -q 'worktree-create.sh' "$D/legacy.json" && { fail=1; echo "FAIL WorktreeCreate still registered at user level"; } || echo "ok user-level WorktreeCreate removed"
grep -q 'other-hook.sh' "$D/legacy.json" && echo "ok foreign hook kept" || { fail=1; echo "FAIL foreign hook lost"; }
DT_SETTINGS="$D/legacy.json" "$SK/scripts/install-hooks.sh" status >/dev/null 2>&1 && echo "ok status after apply" || { fail=1; echo "FAIL status after apply"; }
# --- a second apply must not forget what the first one added (the old manifest was truncated before it was read): uninstall leaves nothing behind
cp "$D/orig.json" "$D/again.json"
DT_SETTINGS="$D/again.json" "$SK/scripts/install-hooks.sh" apply --confirmed >/dev/null 2>&1
python3 -I - "$D/again.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["permissions"]["ask"].remove("Bash(gh pr create:*)")
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
DT_SETTINGS="$D/again.json" "$SK/scripts/install-hooks.sh" apply --confirmed >/dev/null 2>&1 && echo "ok second apply re-adds the removed rule" || { fail=1; echo "FAIL second apply"; }
DT_SETTINGS="$D/again.json" "$SK/scripts/install-hooks.sh" uninstall --confirmed >/dev/null 2>&1
python3 -I - "$D/orig.json" "$D/again.json" <<'PY' && echo "ok apply, apply, uninstall leaves nothing behind" || { fail=1; echo "FAIL second apply then uninstall left entries behind"; }
import json, sys
a, b = (json.load(open(x)) for x in sys.argv[1:3])
assert a == b, (a, b)
PY
# --- the scripts the sandbox block and the user-level ask rules name exist and are executable; the gate scripts' ask rules are user level
python3 -I - "$SK" <<'PY' && echo "ok every BOOKKEEPING and GATES script exists and is executable" || { fail=1; echo "FAIL a BOOKKEEPING / GATES script is missing or not executable"; }
import os, sys
sys.path.insert(0, sys.argv[1] + "/scripts"); os.environ["DT_SETTINGS"] = "/nonexistent"
import install_hooks as ih
for n in ih.BOOKKEEPING + ih.SANDBOXED + ih.GATES:
    p = os.path.join(sys.argv[1], "scripts", n)
    assert os.path.isfile(p) and os.access(p, os.X_OK), p
for g in ih.GATES:
    assert "Bash(%s *)" % os.path.join(ih.SKILL, "scripts", g) in ih.ASK, g
for r in ("gh alias *", "gh extension *", "glab alias *", "gh pr checkout *", "glab mr delete *", "gh issue *", "gh api *", "glab -R *"):
    assert "Bash(%s)" % r in ih.ASK, r         # USER level: a project without the sandbox has no project block
assert not set(ih.GATES) & set(ih.BOOKKEEPING) and not set(ih.SANDBOXED) & (set(ih.GATES) | set(ih.BOOKKEEPING))
PY
printf '{"theme":"dark"}\n' > "$D/gate.json"
DT_SETTINGS="$D/gate.json" "$SK/scripts/install-hooks.sh" apply --confirmed >/dev/null 2>&1
python3 -I - "$D/gate.json" "$SK" <<'PY' && echo "ok user-level ask rules for the gate scripts" || { fail=1; echo "FAIL user-level gate ask rules"; }
import json, sys
ask = json.load(open(sys.argv[1]))["permissions"]["ask"]
for g in ("ticket-state.sh", "guard-apply.sh"):
    assert "Bash(%s/scripts/%s *)" % (sys.argv[2], g) in ask, g
PY
python3 -I - "$D/gate.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["permissions"]["ask"] = [r for r in d["permissions"]["ask"] if "guard-apply.sh" not in r]
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
DT_SETTINGS="$D/gate.json" "$SK/scripts/install-hooks.sh" status 2>&1 | grep -q 'missing permission ask: Bash(.*guard-apply.sh \*)' && echo "ok status flags a missing gate ask rule" || { fail=1; echo "FAIL status misses a gate ask rule"; }
DT_SETTINGS="$D/gate.json" "$SK/scripts/install-hooks.sh" uninstall --confirmed >/dev/null 2>&1
python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); assert d=={'theme':'dark'}, d" "$D/gate.json" && echo "ok uninstall removes the gate ask rules" || { fail=1; echo "FAIL uninstall left gate rules"; }
# --- user-level sandbox keys: allowUnsandboxedCommands false + denyWrite for the protected state; uninstall restores the old values exactly
export DELIVER_TICKET_HOME="$D/sbhome"
python3 -I - "$D/sb1.json" <<'PY'
import json, sys
json.dump({"theme": "dark", "sandbox": {"enabled": False, "allowUnsandboxedCommands": True, "filesystem": {"denyWrite": ["/x/y"], "allowWrite": ["/a"]}}}, open(sys.argv[1], "w"), indent=2)
PY
cp "$D/sb1.json" "$D/sb1-orig.json"
DT_SETTINGS="$D/sb1.json" "$SK/scripts/install-hooks.sh" apply --confirmed >/dev/null 2>&1 && echo "ok apply with existing sandbox keys" || { fail=1; echo "FAIL apply with existing sandbox keys"; }
python3 -I - "$D/sb1.json" "$DELIVER_TICKET_HOME" <<'PY' && echo "ok sandbox keys after apply" || { fail=1; echo "FAIL sandbox keys after apply"; }
import json, os, sys
d = json.load(open(sys.argv[1])); r = os.path.realpath(sys.argv[2]); sb = d["sandbox"]
assert sb["allowUnsandboxedCommands"] is False and sb["enabled"] is False and sb["filesystem"]["allowWrite"] == ["/a"]
h = os.path.realpath(os.path.expanduser("~"))
assert sb["filesystem"]["denyWrite"][:6] == ["/x/y", r + "/sessions", r + "/*/closed", r + "/*/guard.json", r + "/*/delivery.log", r + "/*/approvals"], sb["filesystem"]["denyWrite"]
assert h + "/.gitconfig" in sb["filesystem"]["denyWrite"] and h + "/.config/git/**" in sb["filesystem"]["denyWrite"], sb["filesystem"]["denyWrite"]   # C5b: the user's git config
assert r + "/starts" in sb["filesystem"]["denyWrite"], sb["filesystem"]["denyWrite"]   # C9a: the session start-dir records
for x in ("/.ssh/**", "/.netrc", "/.config/gh/**", "/.config/glab-cli/**", "/.claude/settings*"):
    assert h + x in sb["filesystem"]["denyWrite"], (x, sb["filesystem"]["denyWrite"])   # C9a: what git-push.sh / gh / glab read and can execute from
PY
DT_SETTINGS="$D/sb1.json" "$SK/scripts/install-hooks.sh" status >/dev/null 2>&1 && echo "ok status with sandbox keys" || { fail=1; echo "FAIL status with sandbox keys"; }
DT_SETTINGS="$D/sb1.json" "$SK/scripts/install-hooks.sh" apply --confirmed 2>&1 | grep -q "already installed" && echo "ok apply is idempotent" || { fail=1; echo "FAIL apply is not idempotent"; }
python3 -I - "$D/sb1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["sandbox"]["allowUnsandboxedCommands"] = True
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
DT_SETTINGS="$D/sb1.json" "$SK/scripts/install-hooks.sh" status 2>&1 | grep -q "allowUnsandboxedCommands must be false" && echo "ok status flags allowUnsandboxedCommands true" || { fail=1; echo "FAIL status misses allowUnsandboxedCommands true"; }
DT_SETTINGS="$D/sb1.json" "$SK/scripts/install-hooks.sh" apply --confirmed >/dev/null 2>&1
DT_SETTINGS="$D/sb1.json" "$SK/scripts/install-hooks.sh" uninstall --confirmed >/dev/null 2>&1 && echo "ok uninstall with sandbox keys" || { fail=1; echo "FAIL uninstall with sandbox keys"; }
python3 -I - "$D/sb1.json" <<'PY' && echo "ok old sandbox values restored" || { fail=1; echo "FAIL old sandbox values not restored"; }
import json, sys
sb = json.load(open(sys.argv[1]))["sandbox"]
assert sb["allowUnsandboxedCommands"] is True, sb
assert sb["filesystem"] == {"denyWrite": ["/x/y"], "allowWrite": ["/a"]}, sb
PY
# without any sandbox key: created by apply, gone after uninstall (byte-identical)
printf '{\n  "theme": "dark"\n}\n' > "$D/sb2.json"; cp "$D/sb2.json" "$D/sb2-orig.json"
DT_SETTINGS="$D/sb2.json" "$SK/scripts/install-hooks.sh" apply --confirmed >/dev/null 2>&1
python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['sandbox']['allowUnsandboxedCommands'] is False and len(d['sandbox']['filesystem']['denyWrite'])>=6" "$D/sb2.json" && echo "ok sandbox block created" || { fail=1; echo "FAIL sandbox block not created"; }
DT_SETTINGS="$D/sb2.json" "$SK/scripts/install-hooks.sh" uninstall --confirmed >/dev/null 2>&1
cmp -s "$D/sb2-orig.json" "$D/sb2.json" && echo "ok byte-identical after uninstall (no sandbox keys before)" || { fail=1; echo "FAIL not restored (no sandbox keys before)"; }
# --- C11a: user-level file-tool rules: Read the skill and the state root, Edit tickets/ and evidence/; Edit denied on the protected state and the push record
printf '{\n  "theme": "dark",\n  "permissions": {\n    "allow": [\n      "Bash(ls:*)"\n    ],\n    "deny": [\n      "Read(./secret)"\n    ]\n  }\n}\n' > "$D/ft.json"; cp "$D/ft.json" "$D/ft-orig.json"
DT_SETTINGS="$D/ft.json" "$SK/scripts/install-hooks.sh" apply --confirmed >/dev/null 2>&1 && echo "ok apply with own allow / deny rules" || { fail=1; echo "FAIL apply with own allow / deny rules"; }
python3 -I - "$D/ft.json" "$DELIVER_TICKET_HOME" "$SK" <<'PY' && echo "ok file-tool allow and deny rules after apply" || { fail=1; echo "FAIL file-tool rules after apply"; }
import json, os, sys
p = json.load(open(sys.argv[1]))["permissions"]; r = "/" + os.path.realpath(sys.argv[2]); sk = "/" + os.path.realpath(sys.argv[3])
assert p["allow"] == ["Bash(ls:*)", "Read(%s/**)" % sk, "Read(%s/**)" % r, "Edit(%s/*/tickets/**)" % r, "Edit(%s/*/evidence/**)" % r], p["allow"]
for x in ("sessions/**", "starts/**", "*/closed/**", "*/approvals/**", "*/delivery.log", "*/guard.json", "*/evidence/*/verify.json", "*/evidence/*/.verify.json.tmp"):
    assert "Edit(%s/%s)" % (r, x) in p["deny"], (x, p["deny"])
assert "Read(./secret)" in p["deny"] and not [x for k in p for x in p[k] if x.startswith("Write(")], p      # Edit rules cover Write (probe tool_write_rule_of_its_own)
PY
DT_SETTINGS="$D/ft.json" "$SK/scripts/install-hooks.sh" status >/dev/null 2>&1 && echo "ok status with file-tool rules" || { fail=1; echo "FAIL status with file-tool rules"; }
python3 -I - "$D/ft.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["permissions"]["deny"] = [x for x in d["permissions"]["deny"] if not x.endswith("/*/delivery.log)")]
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
DT_SETTINGS="$D/ft.json" "$SK/scripts/install-hooks.sh" status 2>&1 | grep -q 'missing permission deny: Edit(//.*/\*/delivery.log)' && echo "ok status flags a missing file-tool deny rule" || { fail=1; echo "FAIL status misses a file-tool deny rule"; }
DT_SETTINGS="$D/ft.json" "$SK/scripts/install-hooks.sh" apply --confirmed >/dev/null 2>&1
DT_SETTINGS="$D/ft.json" "$SK/scripts/install-hooks.sh" uninstall --confirmed >/dev/null 2>&1
cmp -s "$D/ft-orig.json" "$D/ft.json" && echo "ok byte-identical after uninstall (own allow / deny rules kept)" || { fail=1; echo "FAIL not restored (own allow / deny rules)"; }
# an install from before C11a (manifest without allow rules, no allow key in the file): apply adds them, uninstall removes them and the allow key it created
cp "$D/sb2-orig.json" "$D/old.json"
DT_SETTINGS="$D/old.json" "$SK/scripts/install-hooks.sh" apply --confirmed >/dev/null 2>&1
python3 -I - "$D/old.json" "$D/old.json.deliver-ticket-manifest.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); del d["permissions"]["allow"]; json.dump(d, open(sys.argv[1], "w"), indent=2)
m = json.load(open(sys.argv[2])); del m["perm_added"]["allow"]; m["perm_keys_created"].remove("allow"); json.dump(m, open(sys.argv[2], "w"), indent=2)
PY
DT_SETTINGS="$D/old.json" "$SK/scripts/install-hooks.sh" status 2>&1 | grep -q 'missing permission allow: Read(//' && echo "ok status flags a pre-C11a install" || { fail=1; echo "FAIL status misses the allow rules of a pre-C11a install"; }
DT_SETTINGS="$D/old.json" "$SK/scripts/install-hooks.sh" apply --confirmed >/dev/null 2>&1 && DT_SETTINGS="$D/old.json" "$SK/scripts/install-hooks.sh" status >/dev/null 2>&1 \
  && echo "ok apply over a pre-C11a manifest" || { fail=1; echo "FAIL apply over a pre-C11a manifest"; }
DT_SETTINGS="$D/old.json" "$SK/scripts/install-hooks.sh" uninstall --confirmed >/dev/null 2>&1
cmp -s "$D/sb2-orig.json" "$D/old.json" && echo "ok byte-identical after uninstall (pre-C11a manifest)" || { fail=1; echo "FAIL not restored (pre-C11a manifest)"; }
# one list of the protected state: every PROTECTED_STATE entry is protected by the hooks; sandbox denyWrite and the Edit deny rules come from it; the push record names
python3 -I - "$SK" "$DELIVER_TICKET_HOME" <<'PY' && echo "ok PROTECTED_STATE = protected_state, the installer derives from it, VERIFY_RECORD = verify_record.py" || { fail=1; echo "FAIL protected-state list"; }
import os, sys
sk, root = sys.argv[1], os.path.realpath(sys.argv[2])
os.environ.update(DT_SETTINGS="/nonexistent", DT_HOME=root, DELIVER_TICKET_HOME=root)
sys.path.insert(0, sk + "/scripts")
import install_hooks as ih
dt = ih.dtcore
for p, isdir in dt.PROTECTED_STATE:
    path = root + "/" + p.replace("*", "proj-0123abcd")
    assert dt.protected_state(path) and (not isdir or dt.protected_state(path + "/x")), p
assert not dt.protected_state(root + "/proj-0123abcd/evidence/T1/verify.json") and not dt.protected_state(root + "/proj-0123abcd/tickets/T1.md")
assert ih.sandbox_deny()[:len(dt.PROTECTED_STATE)] == [root + "/" + p for p, _ in dt.PROTECTED_STATE]
assert len(ih.file_deny()) == len(dt.PROTECTED_STATE) + len(ih.VERIFY_RECORD)
src = open(sk + "/scripts/verify_record.py").read()
assert all('"%s"' % n in src for n in ih.VERIFY_RECORD), ih.VERIFY_RECORD
PY
unset DELIVER_TICKET_HOME
# the user's own global gitignore must not decide these cases: isolate git's global/system config and XDG ignore
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null XDG_CONFIG_HOME="$D/xdg"
# --- project level: apply / status / uninstall round trip on a scratch repo, backup lands in the state dir
export DELIVER_TICKET_HOME="$D/home"; mkdir -p "$DELIVER_TICKET_HOME"
R="$D/proj"; mkdir -p "$R/.claude" && git -C "$R" init -q -b main
printf '{"permissions":{"allow":["Bash(ls)"]},"worktree":{"baseRef":"head"}}\n' > "$R/.claude/settings.local.json"; cp "$R/.claude/settings.local.json" "$D/proj-orig.json"
key=$(bash -c ". \"$SK/hooks/lib.sh\"; dt_key \"$R\""); mkdir -p "$DELIVER_TICKET_HOME/$key"
"$SK/scripts/install-hooks.sh" project-apply --repo "$R" --confirmed >/dev/null 2>&1 && { fail=1; echo "FAIL project-apply without guard.json should refuse"; } || echo "ok project-apply refuses before init (no guard.json)"
printf '{"version":1}\n' > "$DELIVER_TICKET_HOME/$key/guard.json"
# settings.local.json is not git-ignored here: project-diff shows the exclude change, project-apply refuses and writes nothing
"$SK/scripts/install-hooks.sh" project-diff --repo "$R" 2>&1 | grep -q 'NOT git-ignored' && echo "ok project-diff announces the missing ignore" || { fail=1; echo "FAIL project-diff does not announce the missing ignore"; }
"$SK/scripts/install-hooks.sh" project-apply --repo "$R" --confirmed >/dev/null 2>&1; rc=$?
[ $rc = 3 ] && echo "ok project-apply refuses when the file is not git-ignored (rc 3)" || { fail=1; echo "FAIL project-apply rc=$rc when not ignored"; }
cmp -s "$R/.claude/settings.local.json" "$D/proj-orig.json" && [ ! -s "$R/.git/info/exclude" -o -z "$(grep -F settings.local.json "$R/.git/info/exclude" 2>/dev/null)" ] && echo "ok nothing written on refusal" || { fail=1; echo "FAIL something was written on refusal"; }
"$SK/scripts/install-hooks.sh" project-apply --repo "$R" --confirmed --add-exclude >/dev/null 2>&1 && echo "ok project-apply --add-exclude" || { fail=1; echo "FAIL project-apply --add-exclude"; }
grep -qxF '/.claude/settings.local.json' "$R/.git/info/exclude" && git -C "$R" check-ignore -q .claude/settings.local.json && echo "ok exclude line added to info/exclude, file now ignored" || { fail=1; echo "FAIL exclude not added"; }
[ ! -e "$R/.gitignore" ] && echo "ok the repo's .gitignore was not touched" || { fail=1; echo "FAIL .gitignore created"; }
"$SK/scripts/install-hooks.sh" project-status --repo "$R" >/dev/null 2>&1 && echo "ok project-status" || { fail=1; echo "FAIL project-status"; }
grep -q 'worktree-create.sh' "$R/.claude/settings.local.json" && grep -q 'bind-session.sh' "$R/.claude/settings.local.json" && grep -q '"UserPromptSubmit"' "$R/.claude/settings.local.json" && echo "ok both project hooks registered (WorktreeCreate, UserPromptSubmit bind)" || { fail=1; echo "FAIL project hooks missing"; }
python3 -I - "$R/.claude/settings.local.json" <<'PY' && echo "ok bind hook has a timeout and no onFailure (a failure must never erase the user's prompt)" || { fail=1; echo "FAIL bind hook entry"; }
import json, sys
d = json.load(open(sys.argv[1]))
h = d["hooks"]["UserPromptSubmit"][0]["hooks"][0]
sys.exit(0 if h.get("timeout") and "onFailure" not in h else 1)
PY
ls "$DELIVER_TICKET_HOME/$key/backups/" 2>/dev/null | grep -q 'settings.local.json.bak-deliver-ticket-' && echo "ok backup in the state dir" || { fail=1; echo "FAIL no backup in the state dir"; }
[ -z "$(ls "$R/.claude" | grep -v '^settings.local.json$')" ] && echo "ok nothing else written into the repo's .claude" || { fail=1; echo "FAIL extra files in $R/.claude: $(ls "$R/.claude")"; }
grep -q '"baseRef": "head"' "$R/.claude/settings.local.json" && grep -q 'Bash(ls)' "$R/.claude/settings.local.json" && echo "ok existing project settings kept" || { fail=1; echo "FAIL existing settings lost"; }
"$SK/scripts/install-hooks.sh" project-uninstall --repo "$R" --confirmed >/dev/null 2>&1 && echo "ok project-uninstall" || { fail=1; echo "FAIL project-uninstall"; }
python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))==json.load(open(sys.argv[2])) else 1)' "$R/.claude/settings.local.json" "$D/proj-orig.json" && echo "ok project settings restored (semantically identical)" || { fail=1; echo "FAIL project settings not restored"; }
"$SK/scripts/install-hooks.sh" project-status --repo "$R" >/dev/null 2>&1 && { fail=1; echo "FAIL project-status says installed after uninstall"; } || echo "ok project-status: not installed"
# an earlier version registered only WorktreeCreate: status reports the missing bind hook, apply completes it
R5="$D/proj5"; mkdir -p "$R5/.claude" && git -C "$R5" init -q -b main && printf '.claude/settings.local.json\n' > "$R5/.gitignore"
key5=$(bash -c ". \"$SK/hooks/lib.sh\"; dt_key \"$R5\""); mkdir -p "$DELIVER_TICKET_HOME/$key5"; printf '{"version":1}\n' > "$DELIVER_TICKET_HOME/$key5/guard.json"
python3 -I - "$R5/.claude/settings.local.json" "$SK" <<'PY'
import json, os, sys
json.dump({"hooks": {"WorktreeCreate": [{"hooks": [{"type": "command", "command": os.path.join(sys.argv[2], "hooks", "worktree-create.sh"), "timeout": 900}]}]}}, open(sys.argv[1], "w"))
PY
"$SK/scripts/install-hooks.sh" project-status --repo "$R5" >/dev/null 2>&1 && { fail=1; echo "FAIL status should report the missing bind hook"; } || echo "ok status reports the missing bind hook"
"$SK/scripts/install-hooks.sh" project-apply --repo "$R5" --confirmed >/dev/null 2>&1 && "$SK/scripts/install-hooks.sh" project-status --repo "$R5" >/dev/null 2>&1 && echo "ok apply completes a partial project install" || { fail=1; echo "FAIL partial project install"; }
# already ignored (.gitignore): no flag needed, info/exclude untouched
R2="$D/proj2"; mkdir -p "$R2/.claude" && git -C "$R2" init -q -b main && printf '.claude/settings.local.json\n' > "$R2/.gitignore"
key2=$(bash -c ". \"$SK/hooks/lib.sh\"; dt_key \"$R2\""); mkdir -p "$DELIVER_TICKET_HOME/$key2"; printf '{"version":1}\n' > "$DELIVER_TICKET_HOME/$key2/guard.json"
"$SK/scripts/install-hooks.sh" project-apply --repo "$R2" --confirmed >/dev/null 2>&1 && echo "ok project-apply when already ignored" || { fail=1; echo "FAIL project-apply when ignored"; }
grep -qF settings.local.json "$R2/.git/info/exclude" 2>/dev/null && { fail=1; echo "FAIL info/exclude touched although the file was already ignored"; } || echo "ok info/exclude untouched when already ignored"
# tracked by git: never registered
R3="$D/proj3"; mkdir -p "$R3/.claude" && git -C "$R3" init -q -b main && git -C "$R3" config user.email t@t && git -C "$R3" config user.name t
echo '{}' > "$R3/.claude/settings.local.json"; git -C "$R3" add -f .claude/settings.local.json && git -C "$R3" commit -q -m x
key3=$(bash -c ". \"$SK/hooks/lib.sh\"; dt_key \"$R3\""); mkdir -p "$DELIVER_TICKET_HOME/$key3"; printf '{"version":1}\n' > "$DELIVER_TICKET_HOME/$key3/guard.json"
"$SK/scripts/install-hooks.sh" project-apply --repo "$R3" --confirmed --add-exclude >/dev/null 2>&1; rc=$?
[ $rc = 3 ] && [ "$(cat "$R3/.claude/settings.local.json")" = "{}" ] && echo "ok tracked settings.local.json is never touched (rc 3)" || { fail=1; echo "FAIL tracked file: rc=$rc"; }
# ignored only through a global excludesFile (the user's real setup): counts as ignored, nothing added to info/exclude
printf '**/.claude/settings.local.json\n' > "$D/global-ignore"; printf '[core]\n\texcludesFile = %s\n' "$D/global-ignore" > "$D/gitconfig-global"
R4="$D/proj4"; mkdir -p "$R4/.claude" && git -C "$R4" init -q -b main
key4=$(bash -c ". \"$SK/hooks/lib.sh\"; dt_key \"$R4\""); mkdir -p "$DELIVER_TICKET_HOME/$key4"; printf '{"version":1}\n' > "$DELIVER_TICKET_HOME/$key4/guard.json"
GIT_CONFIG_GLOBAL="$D/gitconfig-global" "$SK/scripts/install-hooks.sh" project-apply --repo "$R4" --confirmed >/dev/null 2>&1 && echo "ok project-apply when ignored by a global excludesFile" || { fail=1; echo "FAIL global-ignore case"; }
grep -qF settings.local.json "$R4/.git/info/exclude" 2>/dev/null && { fail=1; echo "FAIL info/exclude touched in the global-ignore case"; } || echo "ok info/exclude untouched in the global-ignore case"
# --- project-level Bash sandbox: project-sandbox-diff / apply / status / off
IH="$SK/scripts/install-hooks.sh"
R5="$D/proj5"; mkdir -p "$R5/.claude" && git -C "$R5" init -q -b main && printf '.claude/settings.local.json\n' > "$R5/.gitignore"
key5=$(bash -c ". \"$SK/hooks/lib.sh\"; dt_key \"$R5\""); ST5="$DELIVER_TICKET_HOME/$key5"; mkdir -p "$ST5"; printf '{"version":1}\n' > "$ST5/guard.json"
printf '{"permissions":{"allow":["Bash(ls)"],"ask":["Bash(git push:*)"]},"sandbox":{"network":{"allowedDomains":["mine.example"]}},"theme":"x"}\n' > "$R5/.claude/settings.local.json"; cp "$R5/.claude/settings.local.json" "$D/proj5-orig.json"
echo '{}' > "$D/user-empty.json"
UH() { DT_SETTINGS="$D/user-sb.json" "$@"; }
"$IH" project-sandbox-apply --repo "$R5" --confirmed >/dev/null 2>&1; rc=$?
[ $rc = 3 ] && cmp -s "$R5/.claude/settings.local.json" "$D/proj5-orig.json" && echo "ok sandbox-apply refuses without the user-level settings (rc 3, nothing written)" || { fail=1; echo "FAIL sandbox-apply without user-level settings: rc=$rc"; }
DT_SETTINGS="$D/user-sb.json" "$IH" apply --confirmed >/dev/null 2>&1
UH "$IH" project-sandbox-apply --repo "$R5" >/dev/null 2>&1; [ $? = 2 ] && echo "ok sandbox-apply needs --confirmed" || { fail=1; echo "FAIL sandbox-apply without --confirmed"; }
UH "$IH" project-sandbox-apply --repo "$R5" --confirmed --domains 'bad host' >/dev/null 2>&1; [ $? = 2 ] && echo "ok sandbox-apply rejects a malformed domain" || { fail=1; echo "FAIL malformed domain accepted"; }
UH "$IH" project-sandbox-diff --repo "$R5" --domains registry.npmjs.org 2>&1 | grep -q 'allowed domains registry.npmjs.org' && echo "ok sandbox-diff names the domains" || { fail=1; echo "FAIL sandbox-diff domains line"; }
cmp -s "$R5/.claude/settings.local.json" "$D/proj5-orig.json" && echo "ok sandbox-diff writes nothing" || { fail=1; echo "FAIL sandbox-diff wrote"; }
UH "$IH" project-sandbox-apply --repo "$R5" --confirmed --domains registry.npmjs.org --local-binding >/dev/null 2>&1 && echo "ok sandbox-apply" || { fail=1; echo "FAIL sandbox-apply"; }
python3 -I - "$R5/.claude/settings.local.json" "$SK" "$R5" "$ST5" <<'PY' && echo "ok sandbox entries (exact set)" || { fail=1; echo "FAIL sandbox entries"; }
import json, os, sys
d = json.load(open(sys.argv[1])); sk, repo, st = sys.argv[2], os.path.realpath(sys.argv[3]), os.path.realpath(sys.argv[4])
sb, pm = d["sandbox"], d["permissions"]
assert sb["enabled"] is True and sb["failIfUnavailable"] is True and sb["network"]["allowLocalBinding"] is True
assert sb["network"]["allowedDomains"] == ["mine.example", "registry.npmjs.org"], sb["network"]
assert sb["filesystem"]["allowWrite"] == [st + "/evidence", repo + "/.claude/worktrees"], sb["filesystem"]
assert sb["filesystem"]["denyWrite"] == [repo + "/.claude/settings.json", repo + "/.claude/settings.local.json", repo + "/.claude/worktrees/*/.claude/settings*.json"], sb["filesystem"]   # C9b
ex = sb["excludedCommands"]
for n in ("session-map.sh", "pending-ticket.sh", "project-map-stale.sh", "git-rename.sh", "ticket-state.sh", "guard-apply.sh", "git-push.sh", "approve-plan.sh"):
    assert "%s/scripts/%s *" % (sk, n) in ex, n
# C5: plain git push / git branch -m are NOT excluded (their hooks would run worktree code unsandboxed); only the scripts are
assert "git push *" not in ex and "git branch -m *" not in ex and not any(e.startswith("git ") for e in ex), ex
for e in ("gh api *", "glab api *", "gh pr create *", "glab mr create *", "gh pr view *", "glab mr list *", "gh -R *", "glab --repo *",
          "gh alias *", "gh extension *", "gh pr checkout *", "glab mr delete *", "glab alias *"):
    assert e in ex, e
assert "gh *" not in ex and "glab *" not in ex            # only the enumerated forms leave the sandbox
sys.path.insert(0, sk + "/scripts"); os.environ["DT_SETTINGS"] = "/nonexistent"
import install_hooks as ih
cli = [e for e in ex if e.split()[0] in ("gh", "glab")]
user_ask = {r.replace(":*)", " *)") for r in ih.ASK}
# invariant: every gh / glab form that runs unsandboxed is gated (an ask rule, user level or project) or a narrow read (allow rule)
assert all(("Bash(%s)" % e) in set(pm["ask"]) | set(pm["allow"]) | user_ask for e in cli), [e for e in cli if ("Bash(%s)" % e) not in set(pm["ask"]) | set(pm["allow"]) | user_ask]
assert set(cli) == set(ih.CLI_ASK) | set(ih.CLI_CREATE) | set(ih.CLI_ALLOW)
assert "Bash(git branch -m:*)" in ih.ASK and "Bash(git push:*)" in ih.ASK and ("Bash(%s/scripts/git-push.sh *)" % sk) in ih.ASK   # user level, so a project-side settings edit cannot drop it
assert all(("Bash(%s)" % r) in ih.ASK for r in ih.CLI_ASK)   # the user-level ask list carries the whole CLI_ASK
assert not any(e.startswith("bash ") for e in ex)
assert "allowUnsandboxedCommands" not in sb      # that one is user level
al, ask = pm["allow"], pm["ask"]
assert al[0] == "Bash(ls)" and "Bash(git branch -m *)" not in al and "Bash(git branch -m *)" not in ask and "Bash(%s/scripts/git-push.sh *)" % sk in ask and "Bash(%s/scripts/git-push.sh *)" % sk not in al and "Bash(%s/scripts/git-rename.sh *)" % sk in al and "Bash(glab mr view *)" in al and "Bash(gh pr list *)" in al
for n in ("session-map.sh", "pending-ticket.sh", "project-map-stale.sh"):
    assert "Bash(%s/scripts/%s *)" % (sk, n) in al and "Bash(%s/scripts/%s *)" % (sk, n) not in ask
assert "Bash(%s/scripts/plan-hash.sh *)" % sk in al and "Bash(%s/scripts/plan-hash.sh *)" % sk not in ask and (sk + "/scripts/plan-hash.sh *") not in ex   # read-only, sandboxed, allow rule
assert "Bash(%s/scripts/verify-record.sh *)" % sk in al and "Bash(%s/scripts/verify-record.sh *)" % sk not in ask and (sk + "/scripts/verify-record.sh *") not in ex   # sandboxed on purpose
assert "Bash(%s/scripts/lock-trace.sh *)" % sk in al and "Bash(%s/scripts/lock-trace.sh *)" % sk not in ask and (sk + "/scripts/lock-trace.sh *") not in ex   # read-only stage 8 trace, sandboxed
for n in ("ticket-state.sh", "guard-apply.sh"):
    assert "Bash(%s/scripts/%s *)" % (sk, n) in ask and "Bash(%s/scripts/%s *)" % (sk, n) not in al, n
assert ask[0] == "Bash(git push:*)"
for r in ("glab api *", "gh api *", "gh auth *", "glab auth *", "gh secret *", "gh -R *", "gh --repo *", "glab -R *", "glab --repo *", "gh repo *", "gh run *", "gh workflow *", "glab ci *", "glab mr update *", "gh pr edit *"):
    assert "Bash(%s)" % r in ask, r
assert not any(a in ask for a in ("Bash(glab *)", "Bash(gh *)"))   # a broad ask would beat the narrow allows
assert not [a for a in al if a in ask]
assert d["theme"] == "x"
PY
[ -d "$ST5/evidence" ] && echo "ok evidence dir created in the state dir" || { fail=1; echo "FAIL evidence dir"; }
ls "$ST5/backups" 2>/dev/null | grep -q 'settings.local.json.bak-deliver-ticket' && echo "ok backup in the state dir" || { fail=1; echo "FAIL backup"; }
[ "$(ls -A "$R5/.claude")" = "settings.local.json" ] && echo "ok nothing else written into the repo's .claude" || { fail=1; echo "FAIL extra files in .claude"; }
UH "$IH" project-sandbox-status --repo "$R5" >/dev/null 2>&1 && echo "ok sandbox-status: on" || { fail=1; echo "FAIL sandbox-status"; }
cp "$R5/.claude/settings.local.json" "$D/proj5-on.json"
UH "$IH" project-sandbox-apply --repo "$R5" --confirmed --domains registry.npmjs.org --local-binding 2>&1 | grep -q 'already enabled' && cmp -s "$R5/.claude/settings.local.json" "$D/proj5-on.json" && echo "ok sandbox-apply is idempotent" || { fail=1; echo "FAIL sandbox-apply not idempotent"; }
UH "$IH" project-sandbox-apply --repo "$R5" --confirmed --domains registry.npmjs.org,cdn.playwright.dev --local-binding >/dev/null 2>&1 && grep -q cdn.playwright.dev "$R5/.claude/settings.local.json" && echo "ok a second apply adds a domain" || { fail=1; echo "FAIL second apply with another domain"; }
python3 -I - "$R5/.claude/settings.local.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["sandbox"]["excludedCommands"].remove("gh api *")
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
UH "$IH" project-sandbox-status --repo "$R5" 2>&1 | grep -q 'DRIFT' && echo "ok sandbox-status reports drift" || { fail=1; echo "FAIL sandbox-status misses drift"; }
UH "$IH" project-sandbox-apply --repo "$R5" --confirmed --domains registry.npmjs.org,cdn.playwright.dev --local-binding >/dev/null 2>&1
UH "$IH" project-sandbox-off --repo "$R5" 2>&1 | grep -q 'dry run' && echo "ok sandbox-off without --confirmed is a dry run" || { fail=1; echo "FAIL sandbox-off dry run"; }
UH "$IH" project-sandbox-off --repo "$R5" --confirmed >/dev/null 2>&1 && echo "ok sandbox-off" || { fail=1; echo "FAIL sandbox-off"; }
python3 -I - "$R5/.claude/settings.local.json" "$D/proj5-orig.json" <<'PY' && echo "ok apply, apply, apply, off restores the settings (semantically identical)" || { fail=1; echo "FAIL settings not restored after sandbox-off"; }
import json, sys
a, b = (json.load(open(x)) for x in sys.argv[1:3])
assert a == b, (a, b)
PY
UH "$IH" project-sandbox-status --repo "$R5" >/dev/null 2>&1 && { fail=1; echo "FAIL sandbox-status says on after off"; } || echo "ok sandbox-status: off after off"
# migration: an earlier apply excluded all of gh / glab; a re-apply prunes what it added and the plan no longer has, keeps the user's own entries
R9="$D/proj9"; mkdir -p "$R9/.claude" && git -C "$R9" init -q -b main && printf '.claude/settings.local.json\n' > "$R9/.gitignore"
key9=$(bash -c ". \"$SK/hooks/lib.sh\"; dt_key \"$R9\""); ST9="$DELIVER_TICKET_HOME/$key9"; mkdir -p "$ST9"; printf '{"version":1}\n' > "$ST9/guard.json"
printf '{"sandbox":{"excludedCommands":["my-tool *"]},"permissions":{"allow":["Bash(ls)"]}}\n' > "$R9/.claude/settings.local.json"; cp "$R9/.claude/settings.local.json" "$D/proj9-orig.json"
UH "$IH" project-sandbox-apply --repo "$R9" --confirmed --domains registry.npmjs.org >/dev/null 2>&1
python3 -I - "$R9/.claude/settings.local.json" "$ST9/sandbox-manifest.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); m = json.load(open(sys.argv[2]))
d["sandbox"]["excludedCommands"] += ["glab *", "gh *"]; m["added"]["sandbox/excludedCommands"] += ["glab *", "gh *"]
json.dump(d, open(sys.argv[1], "w"), indent=2); json.dump(m, open(sys.argv[2], "w"), indent=2)
PY
UH "$IH" project-sandbox-apply --repo "$R9" --confirmed --domains registry.npmjs.org >/dev/null 2>&1
python3 -I - "$R9/.claude/settings.local.json" <<'PY' && echo "ok re-apply prunes the old bare gh / glab exclusion and keeps the user's entries" || { fail=1; echo "FAIL migration prune"; }
import json, sys
ex = json.load(open(sys.argv[1]))["sandbox"]["excludedCommands"]
assert "gh *" not in ex and "glab *" not in ex and "my-tool *" in ex and "gh api *" in ex, ex
PY
UH "$IH" project-sandbox-off --repo "$R9" --confirmed >/dev/null 2>&1
python3 -I - "$R9/.claude/settings.local.json" "$D/proj9-orig.json" <<'PY' && echo "ok off after the migration restores the original" || { fail=1; echo "FAIL off after migration"; }
import json, sys
a, b = (json.load(open(x)) for x in sys.argv[1:3]); assert a == b, (a, b)
PY
# a project with no sandbox keys at all: created by apply, gone after off
R6="$D/proj6"; mkdir -p "$R6" && git -C "$R6" init -q -b main && printf '.claude/settings.local.json\n' > "$R6/.gitignore"
key6=$(bash -c ". \"$SK/hooks/lib.sh\"; dt_key \"$R6\""); mkdir -p "$DELIVER_TICKET_HOME/$key6"; printf '{"version":1}\n' > "$DELIVER_TICKET_HOME/$key6/guard.json"
UH "$IH" project-sandbox-apply --repo "$R6" --confirmed >/dev/null 2>&1 && echo "ok sandbox-apply on a project without settings (no domains: empty allowlist)" || { fail=1; echo "FAIL sandbox-apply on a fresh project"; }
python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['sandbox']['network']['allowedDomains']==[]" "$R6/.claude/settings.local.json" && echo "ok empty allowedDomains without --domains" || { fail=1; echo "FAIL allowedDomains"; }
python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); assert 'allowLocalBinding' not in d['sandbox']['network']" "$R6/.claude/settings.local.json" && echo "ok allowLocalBinding is opt-in" || { fail=1; echo "FAIL allowLocalBinding set without the flag"; }
UH "$IH" project-sandbox-off --repo "$R6" --confirmed >/dev/null 2>&1
[ "$(tr -d ' \n' < "$R6/.claude/settings.local.json")" = "{}" ] && echo "ok sandbox-off leaves {} on a project that had no settings" || { fail=1; echo "FAIL sandbox-off on fresh project: $(cat "$R6/.claude/settings.local.json")"; }
UH "$IH" project-sandbox-off --repo "$R6" --confirmed >/dev/null 2>&1; [ $? = 1 ] && echo "ok sandbox-off twice: no manifest, rc 1" || { fail=1; echo "FAIL second sandbox-off"; }
# no guard.json, and a tracked settings file
R7="$D/proj7"; mkdir -p "$R7" && git -C "$R7" init -q -b main && printf '.claude/settings.local.json\n' > "$R7/.gitignore"
UH "$IH" project-sandbox-apply --repo "$R7" --confirmed >/dev/null 2>&1; [ $? = 2 ] && echo "ok sandbox-apply refuses before init (no guard.json)" || { fail=1; echo "FAIL sandbox-apply without guard.json"; }
UH "$IH" project-sandbox-apply --repo "$R3" --confirmed --add-exclude >/dev/null 2>&1; [ $? = 3 ] && [ "$(cat "$R3/.claude/settings.local.json")" = "{}" ] && echo "ok sandbox-apply never touches a tracked settings file" || { fail=1; echo "FAIL sandbox-apply on a tracked file"; }
R8="$D/proj8"; mkdir -p "$R8" && git -C "$R8" init -q -b main
key8=$(bash -c ". \"$SK/hooks/lib.sh\"; dt_key \"$R8\""); mkdir -p "$DELIVER_TICKET_HOME/$key8"; printf '{"version":1}\n' > "$DELIVER_TICKET_HOME/$key8/guard.json"
UH "$IH" project-sandbox-apply --repo "$R8" --confirmed >/dev/null 2>&1; [ $? = 3 ] && [ ! -e "$R8/.claude/settings.local.json" ] && echo "ok sandbox-apply refuses when the file is not git-ignored" || { fail=1; echo "FAIL sandbox-apply on a non-ignored file"; }
[ $fail = 0 ] && echo "installer: pass" || echo "installer: FAIL"; exit $fail
