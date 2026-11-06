#!/bin/bash
# apply + uninstall on a copy of a settings file must restore it byte for byte.
# usage: tests/run-installer.sh <new-or-empty scratch dir> [settings file to copy; default ~/.claude/settings.json]
set -u
SK="$(cd "$(dirname "$0")/.." && pwd)"
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
[ $fail = 0 ] && echo "installer: pass" || echo "installer: FAIL"; exit $fail
