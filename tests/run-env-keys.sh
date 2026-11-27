#!/bin/bash
# env-keys.sh (C11h: a bookkeeping script, excluded from the sandbox): key names only, for a .env* file whose realpath lies under the repo_root of the project's
# guard.json (delivery state), never trusting .git entries on disk (C11h h). Usage: tests/run-env-keys.sh <new scratch dir>. Never deletes anything.
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
[ -z "$(ls -A "$S")" ] || { echo "scratch dir not empty" >&2; exit 2; }
pass=0; fail=0
eq() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
hasnt() { printf '%s' "$1" | grep -q -- "$2" && { fail=$((fail+1)); echo "FAIL $3: found [$2]"; } || pass=$((pass+1)); }
export DELIVER_TICKET_HOME=$S/state
EK=$SK/scripts/env-keys.sh
R=$S/repo; W=$R/.claude/worktrees/T1; O=$S/outside
mkdir -p "$R/apps/web" "$O/proj" && cd "$R" && git init -q -b main && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git worktree add -q "$W" -b feat-T1
key=$(bash -c '. "$1/hooks/lib.sh"; dt_key "$2"' _ "$SK" "$R")
mkdir -p "$DELIVER_TICKET_HOME/$key" && printf '{"version":1,"repo_root":"%s"}\n' "$R" > "$DELIVER_TICKET_HOME/$key/guard.json"
printf 'API_KEY=value-main-1\nexport DB_URL="postgres://u:pw@h/db"\n' > "$R/apps/web/.env.local"
printf 'OUTSIDE_KEY=value-outside-9\n' > "$O/.env"
printf 'NOT_ENV=value-pkg\n' > "$R/package.json"
ln -s "$R/apps/web/.env.local" "$W/.env.local"                 # the worktree's env link (worktree-create.sh makes these)
ln -s "$O/.env" "$W/.env.outside"                              # named .env*, points outside the repo
ln -s "$R/package.json" "$W/.env.pkg"                          # named .env*, points to a non-env file inside the repo
ln -s "$R/apps/web/.env.local" "$W/notenv.txt"                 # not named .env*, points to an env file
run() { local d=$1; shift; (cd "$d" && "$EK" "$@") > "$S/out.txt" 2> "$S/err.txt"; echo $?; }

echo "# the project key the script computes from --repo is the hooks' (lib.sh dt_key, from git): same state dir"
eq "$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import env_keys; print(env_keys.project_key(sys.argv[2]))' "$SK/scripts" "$R")" "$key" "project key = dt_key"

echo "# allowed: a file in the main checkout, from the main checkout and from a ticket worktree (env link into the main checkout); names only"
eq "$(run "$R" apps/web/.env.local --repo "$R")" 0 "main checkout, relative path"
eq "$(tr '\n' ' ' < "$S/out.txt")" "API_KEY DB_URL " "names"
eq "$(run "$W" "$W/.env.local" --repo "$R")" 0 "ticket worktree: the real env link into the main checkout"
eq "$(tr '\n' ' ' < "$S/out.txt")" "API_KEY DB_URL " "names through the link"
eq "$(run "$R/apps" --repo "$R" ../apps/web/.env.local)" 0 "--repo first, a subdirectory as cwd"
for v in value-main-1 postgres pw@h; do hasnt "$(cat "$S/out.txt" "$S/err.txt")" "$v" "no value printed"; done

echo "# C11h h: a fake .git in a worktree subdirectory (the sandbox allows writing it) pointing outside does not move the boundary"
mkdir -p "$W/sub" "$O/.git/worktrees/x" && printf 'gitdir: %s/.git/worktrees/x\n' "$O" > "$W/sub/.git" && printf '../..\n' > "$O/.git/worktrees/x/commondir"   # "main checkout" = $O, which holds $O/.env
eq "$(run "$W/sub" "$O/.env" --repo "$R")" 2 "fake .git, file outside the repo: refused"
eq "$(cat "$S/out.txt")" "" "fake .git: no output"
hasnt "$(cat "$S/err.txt")" "value-outside" "fake .git: no value in the message"
eq "$(run "$W/sub" "$O/.env" --repo "$W/sub")" 2 "--repo = the fake checkout: no delivery state for it, refused"
eq "$(run "$W/sub" "$O/.env" --repo "$O")" 2 "--repo = what the fake .git points to: no delivery state, refused"
eq "$(run "$W/sub" "$W/.env.local" --repo "$R")" 0 "from the same subdirectory the real env link still works"
echo "# guard.json must name --repo itself (a guard.json under the fake checkout's key, naming the real repo, is refused); a project without state is refused (init before step 2)"
key2=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import env_keys; print(env_keys.project_key(sys.argv[2]))' "$SK/scripts" "$O")
mkdir -p "$DELIVER_TICKET_HOME/$key2" && printf '{"version":1,"repo_root":"%s"}\n' "$R" > "$DELIVER_TICKET_HOME/$key2/guard.json"
eq "$(run "$O" "$O/.env" --repo "$O")" 2 "a guard.json whose repo_root is another directory: refused"
mkdir -p "$S/fresh" && (cd "$S/fresh" && git init -q -b main) && printf 'FRESH=1\n' > "$S/fresh/.env.example"
eq "$(run "$S/fresh" .env.example --repo "$S/fresh")" 2 "no delivery state (not initialised): refused"
grep -q 'project not initialised' "$S/err.txt"; eq $? 0 "says not initialised"

echo "# refused (exit 2, nothing printed on stdout)"
eq "$(run "$W" "$W/.env.outside" --repo "$R")" 2 "symlink named .env* pointing outside the repo"
eq "$(cat "$S/out.txt")" "" "outside: no output"
eq "$(run "$W" "$W/.env.pkg" --repo "$R")" 2 "symlink named .env* pointing to a non-env file"
eq "$(run "$W" "$W/notenv.txt" --repo "$R")" 2 "a non-.env name pointing to an env file"
eq "$(run "$R" package.json --repo "$R")" 2 "a non-env file"
eq "$(run "$R" "$O/.env" --repo "$R")" 2 "an env file outside the repo, absolute path"
mkdir -p "$R/.git/x" && printf 'GIT_INNER=1\n' > "$R/.git/x/.env"
eq "$(run "$R" .git/x/.env --repo "$R")" 2 "a .env* file under .git"
mkdir -p "$R/apps/.GIT/y" && printf 'GIT_CASE=1\n' > "$R/apps/.GIT/y/.env"
eq "$(run "$R" apps/.GIT/y/.env --repo "$R")" 2 "a .env* file under a .GIT component (case-folded)"
eq "$(run "$R" apps/web/.env.local)" 2 "no --repo"
eq "$(run "$R")" 2 "no argument"
eq "$(run "$R" --help)" 2 "an option"
eq "$(run "$R" apps/web/.env.local --repo "$R" extra)" 2 "an extra argument"
eq "$(run "$R" --repo "$R" --repo "$R")" 2 "--repo twice"
echo "# missing file: exit 1"
eq "$(run "$R" apps/.env.missing --repo "$R")" 1 "missing"
echo "# a case-variant name is still an env file (macOS folds case)"
printf 'CASE_KEY=x\n' > "$R/apps/.ENV.prod"
eq "$(run "$R" apps/.ENV.prod --repo "$R")" 0 ".ENV.prod allowed"
eq "$(cat "$S/out.txt")" "CASE_KEY" ".ENV.prod names"
echo "# the wrapper runs under the fixed environment (C11e3): a PATH / PYTHONPATH from the caller changes nothing"
mkdir -p "$S/fake" && printf '#!/bin/sh\necho FAKE-PYTHON\n' > "$S/fake/python3" && chmod +x "$S/fake/python3"
out=$(cd "$R" && PATH="$S/fake:$PATH" PYTHONPATH="$S/fake" "$EK" apps/web/.env.local --repo "$R" 2>&1); eq "$(printf '%s' "$out" | tr '\n' ' ')" "API_KEY DB_URL" "fixed environment"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
