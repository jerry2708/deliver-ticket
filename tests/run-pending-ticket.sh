#!/bin/bash
# pending-ticket.sh: save / list / take for a ticket started before init. Usage: tests/run-pending-ticket.sh <new scratch dir>
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
[ "$(cd "$SK" && pwd -P)" = "$(cd "$HOME/.claude/skills/deliver-ticket" 2>/dev/null && pwd -P)" ] && echo "warning: this suite tests the LIVE checkout $SK - build and test in the dev clone (docs/plan.md, dev-copy process)" >&2
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
[ -z "$(ls -A "$S")" ] || { echo "scratch dir not empty" >&2; exit 2; }
export DELIVER_TICKET_HOME=$S/state; R=$S/repo; mkdir -p "$R" && git -C "$R" init -q -b main
P=$SK/scripts/pending-ticket.sh; pass=0; fail=0
eq() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
key=$(bash -c ". \"$SK/hooks/lib.sh\"; dt_key \"$R\"")
out=$(printf 'WL-09 Add a thing\nAC1: it works\n' | $P save WL-09 --repo "$R"); eq "$?" 0 "save rc"
eq "$out" "$S/state/$key/pending/WL-09.md" "save prints the path in the project's state dir"
grep -q 'AC1: it works' "$out" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL content not saved"; }
[ ! -e "$S/state/$key/guard.json" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL save must not create guard.json (hooks stay no-ops)"; }
printf 'again' | $P save WL-09 --repo "$R" >/dev/null 2>&1; eq "$?" 3 "second save refuses to overwrite"
eq "$($P list --repo "$R")" WL-09 "list"
$P take WL-09 --repo "$R" | grep -q 'AC1: it works' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL take"; }
[ -e "$S/state/$key/pending/WL-09.md.consumed" ] && [ ! -e "$S/state/$key/pending/WL-09.md" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL take must rename to .consumed"; }
eq "$($P list --repo "$R")" "" "list after take"
$P take WL-09 --repo "$R" >/dev/null 2>&1; eq "$?" 1 "take twice -> 1"
printf x | $P save '../x' --repo "$R" >/dev/null 2>&1; eq "$?" 2 "unsafe id refused"
# C11e3: pending-ticket.sh is excluded from the sandbox; its body runs under `env -i` with PATH fixed and HOME from the password database
E=$S/evil; mkdir -p "$E/bin" "$E/home"
for n in basename shasum cut dirname date cat mkdir sed ls env id; do printf '#!/bin/sh\ntouch "%s/ran-%s"\nexit 9\n' "$E" "$n" > "$E/bin/$n"; chmod +x "$E/bin/$n"; done
printf 'touch "%s/ran-bash_env"\n' "$E" > "$E/e.sh"
out=$(printf 'WL-10 x\n' | env BASH_ENV="$E/e.sh" "BASH_FUNC_exec%%=() { touch $E/ran-func; }" PATH="$E/bin:$PATH" $P save WL-10 --repo "$R" 2>&1); eq "$?" 0 "save under a hostile environment ($out)"
eq "$out" "$S/state/$key/pending/WL-10.md" "same path under a hostile environment"
eq "$(cd "$E" && ls ran-* 2>/dev/null | tr '\n' ' ')" "" "nothing from the caller's environment ran"
# without DELIVER_TICKET_HOME the default root is under HOME: fixed-env.sh (sourced alone, nothing else runs) passes the passwd home, not $HOME
pw=$(python3 -I -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
eq "$(env -u DELIVER_TICKET_HOME HOME="$E/home" /bin/bash -p -c '. "$1/fixed-env.sh"; printf "%s\n" "${DT_ENV[@]}"' _ "$SK/scripts" | grep '^HOME=')" "HOME=$pw" "fixed-env.sh: HOME from the password database"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
