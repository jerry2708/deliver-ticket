#!/bin/bash
# scripts/install.sh against a FAKE HOME (the real ~/.claude is never touched). Usage: tests/run-install.sh <new scratch dir>
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
[ -z "$(ls -A "$S")" ] || { echo "scratch dir not empty" >&2; exit 2; }
pass=0; fail=0
eq() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
has() { printf '%s' "$1" | grep -q -- "$2" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: missing [$2] in: $(printf '%s' "$1" | head -c 300)"; }; }
hasnt() { printf '%s' "$1" | grep -q -- "$2" && { fail=$((fail+1)); echo "FAIL $3: unexpected [$2]"; } || pass=$((pass+1)); }
mkhome() { H=$S/$1; mkdir -p "$H/.claude/skills"; ln -s "$SK" "$H/.claude/skills/deliver-ticket"; echo '{"theme":"dark"}' > "$H/.claude/settings.json"; }
sum() { shasum "$1" | cut -d' ' -f1; }
REAL=${REAL_HOME_FOR_TEST:-$(eval echo ~)}/.claude/settings.json; REALSUM=$(sum "$REAL" 2>/dev/null)

echo "# n, empty input and a stray key write nothing"
for case in n "" x; do
  mkhome "h_$case"; b=$(sum "$H/.claude/settings.json")
  out=$(printf '%s\n' "$case" | HOME=$H bash "$SK/scripts/install.sh" 2>&1); rc=$?
  eq "$rc" 0 "answer [$case]: rc"; has "$out" "Nothing written" "answer [$case]: says so"
  eq "$(sum "$H/.claude/settings.json")" "$b" "answer [$case]: settings.json unchanged"
  eq "$(ls -A "$H/.claude" | grep -c bak)" 0 "answer [$case]: no backup (nothing was written)"
done
mkhome h_eof; b=$(sum "$H/.claude/settings.json"); out=$(HOME=$H bash "$SK/scripts/install.sh" </dev/null 2>&1); eq "$(sum "$H/.claude/settings.json")" "$b" "closed stdin writes nothing"

echo "# y applies, backs up, runs status, prints the init reminder"
mkhome h_y; out=$(printf 'y\n' | HOME=$H bash "$SK/scripts/install.sh" 2>&1); eq "$?" 0 "y: rc"
NRULES=$(DT_SETTINGS=/nonexistent python3 -I -c "import sys; sys.path.insert(0, '$SK/scripts'); import install_hooks as i; print(len(i.ASK) + len(i.DENY))")
has "$out" "all 5 hooks and $NRULES permission rules registered" "y: status output"
has "$out" "/deliver-ticket init" "y: init reminder"
eq "$(ls -A "$H/.claude" | grep -c 'settings.json.bak')" 1 "y: one backup next to settings.json"
eq "$(python3 -c "import json;d=json.load(open('$H/.claude/settings.json'));print(d['theme'], len(d['hooks']), len(d['permissions']['deny']))")" "dark 3 3" "y: existing keys kept, hook events and deny rules added"
has "$out" "ok   git" "tools checked"; has "$out" "ok   $SK" "clone path ok"

echo "# wrong clone path: nothing is written"
mkhome h_wp; mkdir -p "$S/copy"; cp -R "$SK/scripts" "$SK/hooks" "$S/copy/"; b=$(sum "$H/.claude/settings.json")
out=$(printf 'y\n' | HOME=$H bash "$S/copy/scripts/install.sh" 2>&1); eq "$?" 1 "wrong path: rc 1"
has "$out" "clone it to exactly $H/.claude/skills/deliver-ticket" "wrong path: names the path"
eq "$(sum "$H/.claude/settings.json")" "$b" "wrong path: settings.json unchanged"

echo "# old claude: warning, still asks"
mkhome h_old; mkdir -p "$S/fakebin"; printf '#!/bin/sh\necho "2.0.1 (Claude Code)"\n' > "$S/fakebin/claude"; chmod +x "$S/fakebin/claude"
out=$(printf 'n\n' | PATH="$S/fakebin:$PATH" HOME=$H bash "$SK/scripts/install.sh" 2>&1); eq "$?" 0 "old claude: rc 0"
has "$out" "WARNING claude version '2.0.1' is below the tested minimum" "old claude: warning"

echo "# the real settings.json was not touched"
eq "$(sum "$REAL")" "$REALSUM" "real ~/.claude/settings.json byte-identical after the whole test"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
