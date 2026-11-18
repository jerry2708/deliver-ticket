#!/bin/bash
# compare-failures.py: same failure on base and ticket = pre-existing; only on the ticket = new. Usage: tests/run-compare.sh <new scratch dir>
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
[ "$(cd "$SK" && pwd -P)" = "$(cd "$HOME/.claude/skills/deliver-ticket" 2>/dev/null && pwd -P)" ] && echo "warning: this suite tests the LIVE checkout $SK - build and test in the dev clone (docs/plan.md, dev-copy process)" >&2
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
[ -z "$(ls -A "$S")" ] || { echo "scratch dir not empty" >&2; exit 2; }
pass=0; fail=0
eq() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
printf '\033[31mERROR\033[0m 404 Not Found - GET https://registry/@repo/shared (12ms)\nPASS a.test.ts (3.1s)\nFAIL b.test.ts > adds items (45ms)\nTests 1 failed | 4 passed\n/base/apps/web/x.ts\n  3:1  error  Unexpected any  @typescript-eslint/no-explicit-any\n' > "$S/base.txt"
# same failures, different timings and checkout path -> pre-existing only
printf 'ERROR 404 Not Found - GET https://registry/@repo/shared (99ms)\nPASS a.test.ts (0.4s)\nFAIL b.test.ts > adds items (7ms)\nTests 1 failed | 4 passed\n/wt/T1/apps/web/x.ts\n  3:1  error  Unexpected any  @typescript-eslint/no-explicit-any\n' > "$S/same.txt"
out=$("$SK/scripts/compare-failures.py" "$S/base.txt" "$S/same.txt" --root-base /base --root-ticket /wt/T1); rc=$?
eq "$rc" 0 "same -> rc 0"; echo "$out" | grep -q '^new: 0' && echo "$out" | grep -q '^pre-existing: 4' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL same: $out"; }
# one extra failure on the ticket -> new, rc 1
cp "$S/same.txt" "$S/more.txt"; printf 'FAIL c.test.ts > new regression (5ms)\n' >> "$S/more.txt"
out=$("$SK/scripts/compare-failures.py" "$S/base.txt" "$S/more.txt" --root-base /base --root-ticket /wt/T1); rc=$?
eq "$rc" 1 "extra -> rc 1"; echo "$out" | grep -q 'FAIL c.test.ts > new regression' && echo "$out" | grep -q '^new: 1' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL extra: $out"; }
# a failure fixed on the ticket -> fixed, rc 0
printf 'PASS a.test.ts\n' > "$S/fixed.txt"
out=$("$SK/scripts/compare-failures.py" "$S/base.txt" "$S/fixed.txt"); rc=$?
eq "$rc" 0 "fixed -> rc 0"; echo "$out" | grep -q '^fixed: ' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL fixed: $out"; }
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
