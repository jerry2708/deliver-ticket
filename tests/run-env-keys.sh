#!/bin/bash
# env-keys.sh (C11h: a bookkeeping script, excluded from the sandbox): key names only, and only for a .env* file whose realpath lies in the main checkout of the
# current directory's repo. Usage: tests/run-env-keys.sh <new scratch dir>. Never deletes anything.
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
[ -z "$(ls -A "$S")" ] || { echo "scratch dir not empty" >&2; exit 2; }
pass=0; fail=0
eq() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
hasnt() { printf '%s' "$1" | grep -q -- "$2" && { fail=$((fail+1)); echo "FAIL $3: found [$2]"; } || pass=$((pass+1)); }
EK=$SK/scripts/env-keys.sh
R=$S/repo; W=$R/.claude/worktrees/T1; O=$S/outside
mkdir -p "$R/apps/web" "$O" && cd "$R" && git init -q -b main && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git worktree add -q "$W" -b feat-T1
printf 'API_KEY=value-main-1\nexport DB_URL="postgres://u:pw@h/db"\n' > "$R/apps/web/.env.local"
printf 'OUTSIDE_KEY=value-outside-9\n' > "$O/.env"
printf 'NOT_ENV=value-pkg\n' > "$R/package.json"
ln -s "$R/apps/web/.env.local" "$W/.env.local"                 # the worktree's env link (worktree-create.sh makes these)
ln -s "$O/.env" "$W/.env.outside"                              # named .env*, points outside the repo
ln -s "$R/package.json" "$W/.env.pkg"                          # named .env*, points to a non-env file inside the repo
ln -s "$R/apps/web/.env.local" "$W/notenv.txt"                 # not named .env*, points to an env file
run() { local d=$1; shift; (cd "$d" && "$EK" "$@") > "$S/out.txt" 2> "$S/err.txt"; echo $?; }

echo "# allowed: a file in the main checkout, from the main checkout and from a ticket worktree (env link into the main checkout); names only"
eq "$(run "$R" apps/web/.env.local)" 0 "main checkout, relative path"
eq "$(tr '\n' ' ' < "$S/out.txt")" "API_KEY DB_URL " "names"
eq "$(run "$W" "$W/.env.local")" 0 "ticket worktree: link into the main checkout"
eq "$(tr '\n' ' ' < "$S/out.txt")" "API_KEY DB_URL " "names through the link"
eq "$(run "$R/apps" ../apps/web/.env.local)" 0 "a subdirectory as cwd"
for v in value-main-1 postgres pw@h; do hasnt "$(cat "$S/out.txt" "$S/err.txt")" "$v" "no value printed"; done

echo "# refused (exit 2, nothing printed on stdout)"
eq "$(run "$W" "$W/.env.outside")" 2 "symlink named .env* pointing outside the repo"
eq "$(cat "$S/out.txt")" "" "outside: no output"
hasnt "$(cat "$S/err.txt")" "value-outside" "outside: no value in the message"
eq "$(run "$W" "$W/.env.pkg")" 2 "symlink named .env* pointing to a non-env file"
eq "$(run "$W" "$W/notenv.txt")" 2 "a non-.env name pointing to an env file"
eq "$(run "$R" package.json)" 2 "a non-env file"
eq "$(run "$R" "$O/.env")" 2 "an env file outside the repo, absolute path"
eq "$(run "$O" "$O/.env")" 2 "cwd outside any repo"
eq "$(cat "$S/out.txt")" "" "cwd outside: no output"
mkdir -p "$R/.git/x" && printf 'GIT_INNER=1\n' > "$R/.git/x/.env"
eq "$(run "$R" .git/x/.env)" 2 "a .env* file under .git"
eq "$(run "$R")" 2 "no argument"
eq "$(run "$R" --help)" 2 "an option"
eq "$(run "$R" a b)" 2 "two arguments"
echo "# missing file: exit 1"
eq "$(run "$R" apps/.env.missing)" 1 "missing"
echo "# a case-variant name is still an env file (macOS folds case)"
printf 'CASE_KEY=x\n' > "$R/apps/.ENV.prod"
eq "$(run "$R" apps/.ENV.prod)" 0 ".ENV.prod allowed"
eq "$(cat "$S/out.txt")" "CASE_KEY" ".ENV.prod names"
echo "# the wrapper runs under the fixed environment (C11e3): a PATH / PYTHONPATH from the caller changes nothing"
mkdir -p "$S/fake" && printf '#!/bin/sh\necho FAKE-PYTHON\n' > "$S/fake/python3" && chmod +x "$S/fake/python3"
out=$(cd "$R" && PATH="$S/fake:$PATH" PYTHONPATH="$S/fake" "$EK" apps/web/.env.local 2>&1); eq "$(printf '%s' "$out" | tr '\n' ' ')" "API_KEY DB_URL" "fixed environment"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
