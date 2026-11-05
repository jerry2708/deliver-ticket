#!/bin/bash
# apply + uninstall on a copy of a settings file must restore it byte for byte.
# usage: tests/run-installer.sh <new-or-empty scratch dir> [settings file to copy; default ~/.claude/settings.json]
set -u
SK="$(cd "$(dirname "$0")/.." && pwd)"
D="${1:?scratch dir (must be empty or new)}"
SRC="${2:-$HOME/.claude/settings.json}"
mkdir -p "$D"; [ -z "$(ls -A "$D")" ] || { echo "scratch dir not empty" >&2; exit 1; }
cp "$SRC" "$D/orig.json"; cp "$SRC" "$D/s.json"
export DT_SETTINGS="$D/s.json"
fail=0
"$SK/scripts/install-hooks.sh" apply --confirmed >/dev/null 2>&1 && echo "ok apply" || { fail=1; echo "FAIL apply"; }
"$SK/scripts/install-hooks.sh" status >/dev/null 2>&1 && echo "ok status after apply" || { fail=1; echo "FAIL status after apply"; }
cmp -s "$D/orig.json" "$D/s.json" && { fail=1; echo "FAIL apply changed nothing"; }
"$SK/scripts/install-hooks.sh" uninstall --confirmed >/dev/null 2>&1 && echo "ok uninstall" || { fail=1; echo "FAIL uninstall"; }
cmp -s "$D/orig.json" "$D/s.json" && echo "ok byte-identical after uninstall" || { fail=1; echo "FAIL not restored"; }
"$SK/scripts/install-hooks.sh" status >/dev/null 2>&1 && { fail=1; echo "FAIL status says installed after uninstall"; } || echo "ok status: not installed"
[ $fail = 0 ] && echo "installer: pass" || echo "installer: FAIL"; exit $fail
