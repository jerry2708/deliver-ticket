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
echo "# backlog item 10 (no plan mode in stage 2)"
has stages/2-plan.md 'Do not use plan mode'
has stages/2-plan.md 'which the guard blocks (dry runs 2 and 3)'
has stages/2-plan.md 'its exit dialog switches the session to default mode'
has stages/2-plan.md 'is never my approval'
hasnt "SKILL.md init.md README.md stages templates" 'Enter plan mode'
has docs/plan.md 'no plan mode'
echo "# auto mode, no plan mode (documented)"
has README.md 'claude --permission-mode auto'
has README.md 'CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 claude --permission-mode auto'
has README.md 'does not use plan mode'
has README.md 'which the guard blocks (dry runs 2 and 3)'
has README.md 'only policy/user/flag settings may grant auto mode'
hasnt "README.md SKILL.md stages" 'blocks ticket-file writes\|blocks writes to the ticket file'
has SKILL.md 'meant for auto mode'
has SKILL.md 'Do not use plan mode'
has SKILL.md 'which the guard blocks (dry runs 2 and 3)'
has SKILL.md 'its exit dialog switches the session to default mode'
has docs/plan.md 'HIGH PRIORITY – permission mode'
echo "# one state root (eval isolation): the default path is named only where DELIVER_TICKET_HOME is honoured"
has SKILL.md '${DELIVER_TICKET_HOME:-$HOME/.local/share/deliver-ticket}'
has SKILL.md 'This is the only place that names the default'
bad=$(python3 - <<'PY'
import os, re
rx = re.compile(r"\.local/share/deliver-ticket(?!-eval)")
skip_dirs = {".git", "tests", "docs", "evals", "__pycache__"}
for d, dirs, files in os.walk("."):
    dirs[:] = [x for x in dirs if x not in skip_dirs]
    for f in files:
        if f == "CLAUDE.md":
            continue
        p = os.path.join(d, f)
        try:
            lines = open(p).read().splitlines()
        except (UnicodeDecodeError, OSError):
            continue
        for n, l in enumerate(lines, 1):
            if rx.search(l) and "DELIVER_TICKET_HOME" not in l and "OUTSIDE_MARKERS" not in l:
                print("%s:%d: %s" % (p, n, l.strip()[:100]))
PY
)
[ -z "$bad" ]; ok $? "files hard-code ~/.local/share/deliver-ticket outside a DELIVER_TICKET_HOME definition:
$bad"
echo "# phase 6 scope"
has docs/plan.md 'v0.1 measures the 8 retro rows only'
has docs/plan.md 'intake verdict \*\*8/8\*\*'
has docs/plan.md 'phase 6b'
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
