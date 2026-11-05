#!/bin/bash
# classify.py floor: risk globs raise it, risk.exclude (test files) never does. Usage: tests/run-classify.sh <new scratch dir>
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
[ -z "$(ls -A "$S")" ] || { echo "scratch dir not empty" >&2; exit 2; }
G=$SK/tests/guard-json/valid.json
pass=0; fail=0
floor() { python3 -I "$SK/scripts/classify.py" --guard "$G" "$@" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["floor"])'; }
eq() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
eq "$(floor --files apps/agent/src/mastra/auth/clerk-auth.ts --lines 10 --acs 1)" C "auth file -> C"
eq "$(floor --files apps/agent/src/mastra/auth/clerk-auth.test.ts --lines 10 --acs 1 --type tests)" A "auth TEST file only -> not raised by the risk glob"
eq "$(floor --files apps/agent/src/mastra/auth/clerk-auth.spec.tsx --lines 10 --acs 1 --type tests)" A "auth spec file only"
eq "$(floor --files apps/agent/src/mastra/auth/clerk-auth.ts apps/agent/src/mastra/auth/clerk-auth.test.ts --lines 10 --acs 1)" C "source + test -> C"
eq "$(floor --files apps/agent/src/mastra/tools/x.test.ts --lines 10 --acs 1 --type tests)" A "agent tool test only"
eq "$(floor --files docs/readme.md --lines 5 --acs 1 --type docs)" A "docs -> A"
# the same guard without exclude: the test file raises the floor (proves the exclude is what changes it)
python3 -I -c 'import json,sys; g=json.load(open(sys.argv[1])); g["risk"].pop("exclude"); json.dump(g,open(sys.argv[2],"w"))' "$G" "$S/noexcl.json"
eq "$(python3 -I "$SK/scripts/classify.py" --guard "$S/noexcl.json" --files apps/agent/src/mastra/auth/clerk-auth.test.ts --lines 10 --acs 1 --type tests | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["floor"])')" C "without exclude the test file raises C"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
