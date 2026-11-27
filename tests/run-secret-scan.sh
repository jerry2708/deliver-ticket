#!/bin/bash
# secret-scan.sh: key-looking strings in a ticket's evidence, diff and untracked files, printed masked only. Usage: tests/run-secret-scan.sh <new scratch dir>
# Never deletes anything. The fake keys are assembled at run time, so this file holds no key-looking string itself.
set -u
S=${1:?scratch dir (must be empty or new)}
SK=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$S" && S=$(cd "$S" && pwd -P)
[ -z "$(ls -A "$S")" ] || { echo "scratch dir not empty" >&2; exit 2; }
pass=0; fail=0
eq() { [ "$1" = "$2" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: got [$1] want [$2]"; }; }
has() { printf '%s' "$1" | grep -q -- "$2" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $3: missing [$2] in: $(printf '%s' "$1" | head -c 400)"; }; }
hasnt() { printf '%s' "$1" | grep -q -- "$2" && { fail=$((fail+1)); echo "FAIL $3: found [$2]"; } || pass=$((pass+1)); }
rep() { local c=$1 n=$2 o=""; while [ ${#o} -lt "$n" ]; do o="$o$c"; done; printf '%s' "$o"; }
SKK="sk-$(rep Ab3 30)"; STR="sk""_live_$(rep Zq9 20)"; GH="ghp""_$(rep Xy7 39)"; AWS="AKIA$(rep QW 16)"; PW="Sup3rS3cretValue42"
R=$S/repo; ST=$S/state/proj-0000aaaa; W=$R/.claude/worktrees/T1
mkdir -p "$R" "$ST/evidence/T1/sub" && cd "$R" && git init -q -b main && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
printf '.claude/worktrees/\n.env*\n' > .gitignore && git add .gitignore && git -c user.name=t -c user.email=t@t commit -q -m ignore
git worktree add -q "$W" -b feat-T1
printf '{"repo_root":"%s","base_branch":"main"}\n' "$R" > "$ST/guard.json"
G=$ST/guard.json
run() { "$SK/scripts/secret-scan.sh" "$@" > "$S/out.txt" 2>&1; echo $?; }

echo "# clean ticket: exit 0, says what it scanned"
printf 'all tests passed\n' > "$ST/evidence/T1/stage3-test.txt"
eq "$(run T1 --guard "$G")" 0 "clean: exit 0"
has "$(cat "$S/out.txt")" "secret-scan T1: 0 finding(s); scanned evidence/T1/stage3-test.txt, diff main...HEAD, uncommitted, untracked files" "clean: summary"

echo "# evidence files: each kind found, value masked, line number given"
printf 'line one\nOPENAI=%s\n' "$SKK" > "$ST/evidence/T1/stage3-build.txt"
printf 'x\ny\nkey %s and %s\n' "$STR" "$AWS" > "$ST/evidence/T1/sub/log.txt"
printf 'DB_PASSWORD=%s\n' "$PW" > "$ST/evidence/T1/notes.md"
eq "$(run T1 --guard "$G")" 1 "findings: exit 1"
out=$(cat "$S/out.txt")
has "$out" "evidence/T1/stage3-build.txt:2 api-key-sk sk-A... (33 chars)" "sk- key, masked, line 2"
has "$out" "evidence/T1/sub/log.txt:3 stripe-key" "stripe key in a subdir, line 3"
has "$out" "evidence/T1/sub/log.txt:3 aws-access-key AKIA... (20 chars)" "aws key"
has "$out" "evidence/T1/notes.md:1 assignment:DB_PASSWORD Sup3... (18 chars)" "NAME=value assignment"
for v in "$SKK" "$STR" "$AWS" "$PW"; do hasnt "$out" "$v" "no full value printed"; done
echo "# .env* names, symlinks and binaries in evidence/ are not read"
printf 'API_KEY=%s\n' "$SKK" > "$ST/evidence/T1/.env.local"
ln -s "$ST/evidence/T1/.env.local" "$ST/evidence/T1/link.txt"
printf '\0\0binary %s' "$GH" > "$ST/evidence/T1/blob.bin"
run T1 --guard "$G" >/dev/null; out=$(cat "$S/out.txt")
hasnt "$out" ".env.local:" ".env* in evidence not scanned"
hasnt "$out" "link.txt:" "symlink not followed"
hasnt "$out" "github-token" "binary file not scanned"
has "$out" "skipped evidence/T1/.env.local" "skips listed"

echo "# the diff: committed lines vs the base, uncommitted tracked lines, untracked files; placeholders are not findings"
mkdir -p "$W/src"
printf 'const token = "%s";\nconst API_KEY = process.env.API_KEY;\nconst SECRET = "<your-secret>";\n' "$GH" > "$W/src/a.ts"
git -C "$W" add src/a.ts && git -C "$W" -c user.name=t -c user.email=t@t commit -q -m a
printf 'const x = 1;\n' > "$W/src/b.ts" && git -C "$W" add src/b.ts && git -C "$W" -c user.name=t -c user.email=t@t commit -q -m b
printf 'const x = 1;\nconst k = "%s";\n' "$STR" > "$W/src/b.ts"                                # uncommitted change of a tracked file
printf 'AUTH_TOKEN: %s\n' "$PW" > "$W/new.yml"                                                 # untracked
printf 'API_KEY=%s\n' "$SKK" > "$W/.env.local"                                                # untracked but .env*: not read
eq "$(run T1 --guard "$G")" 1 "diff findings: exit 1"
out=$(cat "$S/out.txt")
has "$out" "diff main...HEAD: src/a.ts:1 github-token ghp_... (43 chars)" "committed line, path and new line number"
has "$out" "uncommitted: src/b.ts:2 stripe-key" "uncommitted tracked change"
has "$out" "untracked: new.yml:1 assignment:AUTH_TOKEN" "untracked file"
hasnt "$out" "process.env" "process.env reference is not a finding"
hasnt "$out" "<your" "placeholder is not a finding"
hasnt "$out" "untracked: .env.local" "untracked .env* not read"
for v in "$GH" "$STR" "$PW" "$SKK"; do hasnt "$out" "$v" "no full value printed (diff)"; done

echo "# refusals: exit 2"
eq "$(run '../T1' --guard "$G")" 2 "path-like id"
eq "$(run T9 --guard "$G")" 2 "no worktree"
eq "$(run T1 --guard "$S/missing.json")" 2 "unreadable guard.json"
printf '{"repo_root":"%s","base_branch":"no-such-branch"}\n' "$R" > "$S/g2.json"; mkdir -p "$S/evidence"
eq "$(run T1 --guard "$S/g2.json")" 2 "unknown base branch: git diff fails -> 2, never a clean 0"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
