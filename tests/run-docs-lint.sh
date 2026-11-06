#!/bin/bash
# Static checks on the skill's own instructions (they only prove the text is there; behaviour is proven by dry runs).
# Usage: tests/run-docs-lint.sh   (reads the skill files, writes nothing)
SK=$(cd "$(dirname "$0")/.." && pwd); cd "$SK" || exit 1
pass=0; fail=0
ok() { if [ "$1" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $2"; fi; }
has() { grep -q -- "$2" "$1"; ok $? "$1 should contain: $2"; }
hasnt() { ! grep -rq -- "$2" $1; ok $? "$1 must not contain: $2"; }
FILES="SKILL.md init.md README.md stages templates"
echo "# skill files are read with absolute paths (backlog item 2)"
hasnt "$FILES" 'cd [^;&|]*deliver-ticket[^;&|]*&&[^;&|]*\(cat\|head\|sed\)'
# an instruction to cd into the skill is only allowed as a prohibition ("Never `cd <skill dir> && ...`")
! grep -rn 'cd <skill' $FILES | grep -vi 'never'  | grep -q .; ok $? "no file tells the reader to cd into the skill dir"
hasnt "SKILL.md init.md stages templates" 'next: read stages/'
has SKILL.md 'Read skill files with the Read tool and an absolute path'
has templates/ticket.md 'next: Read <skill dir>/stages/'
echo "# backlog items 1, 4, 6, 7"
has stages/1b-workspace.md 'scripts/branch-name.py'
has stages/1b-workspace.md 'branch -m'
has stages/4-verify.md 'copied verbatim from the AC'
has stages/4-verify.md 'read `<state>/project.md` Commands'
has stages/4-verify.md 'for every package or app the diff touches'
has templates/ac-evidence.md 'Pass criterion (verbatim from the AC)'
has templates/reviewer-verify.md 'strictly'
has stages/3-build.md 'evidence/<ID>/stage3-<check>.txt'
echo "# rules from dry runs 1-2"
has stages/1-intake.md 'Repo notes are not searched for the ticket'
has SKILL.md 'A cut search is not evidence of absence'
has SKILL.md 'literal absolute paths in Bash'
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
