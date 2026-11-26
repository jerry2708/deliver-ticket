#!/bin/bash
# Static checks on the skill's own instructions (they only prove the text is there; behaviour is proven by dry runs).
# Usage: tests/run-docs-lint.sh   (reads the skill files, writes nothing)
SK=$(cd "$(dirname "$0")/.." && pwd); cd "$SK" || exit 1
[ "$(cd "$SK" && pwd -P)" = "$(cd "$HOME/.claude/skills/deliver-ticket" 2>/dev/null && pwd -P)" ] && echo "warning: this suite tests the LIVE checkout $SK - build and test in the dev clone (docs/plan.md, dev-copy process)" >&2
pass=0; fail=0
ok() { if [ "$1" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $2"; fi; }
has() { grep -q -- "$2" "$1"; ok $? "$1 should contain: $2"; }
hasnt() { ! grep -rq -- "$2" $1; ok $? "$1 must not contain: $2"; }
FILES="SKILL.md init.md README.md stages templates"
echo "# test runners: every helper function is defined before its first use (an undefined helper is 'command not found', rc 127, and silently skips its cases)"
python3 - "$SK" <<'PY'; ok $? "a tests/run-*.sh runner uses a helper before it is defined"
import glob, re, sys
bad = []
for f in sorted(glob.glob(sys.argv[1] + "/tests/run-*.sh")):
    lines = open(f).read().split("\n")
    defs = {}
    for i, l in enumerate(lines):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{", l)
        if m and m.group(1) not in defs:
            defs[m.group(1)] = i
    for name, d in defs.items():
        use = re.compile(r"(^|[;&|(]\s*|\bdo\s+|\bthen\s+|\$\(\s*)" + re.escape(name) + r"\s")
        for i, l in enumerate(lines[:d]):
            if not l.lstrip().startswith("#") and use.search(l):
                bad.append("%s:%d uses %s() before its definition on line %d" % (f, i + 1, name, d + 1)); break
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
echo "# scripts are called the way the sandbox exclusions and the ask rules match (1d step 4): <skill dir>/scripts/<name>.sh, nothing in front"
python3 tests/lint_script_calls.py "$SK"; ok $? "the run-time files call a bookkeeping / gate script in a form the sandbox exclusion or ask rule would not match (lines above)"
for bad in 'run `scripts/ticket-state.sh done T1`' 'run `bash <skill dir>/scripts/session-map.sh show`' 'python3 <skill dir>/scripts/ticket-state.sh x' 'env <skill dir>/scripts/pending-ticket.sh save' \
  'git -C <worktree> branch -m a b' 'git -C <wt> push mirror x' \
  'cd <wt> && git push mirror x' 'cd <wt>; git push mirror x' 'cd <wt> || git push mirror x' 'pushd <wt> && git push mirror x' '(cd <wt> && git push mirror x)' \
  'cd <wt> && git branch -m a b' 'FOO=1 git push mirror x' 'GIT_DIR=<wt>/.git git push mirror x' 'run `FOO=1 git branch -m a b`'; do python3 tests/lint_script_calls.py --text "$bad" >/dev/null; [ $? = 1 ]; ok $? "lint must flag: $bad"; done
for bad in '`claude --version; echo x`' '`<skill dir>/scripts/validate-guard.py g.json && echo ok`' '`<skill dir>/scripts/session-map.sh show T1 | tail -3`' '`claude -v || true`' \
  '`<skill dir>/scripts/env-keys.sh .env;echo`' $'```\nclaude --version; <skill dir>/scripts/validate-guard.py g\n```'; do python3 tests/lint_script_calls.py --text "$bad" >/dev/null; [ $? = 1 ]; ok $? "lint must flag (C11a, one script per call): $bad"; done
for good in '`<skill dir>/scripts/ticket-state.sh done|cancelled <ID>`' '`claude --version`' 'run `claude --version`; then `<skill dir>/scripts/validate-guard.py g`' $'```\nclaude --version\n```\nthen; `claude --version`'; do
  python3 tests/lint_script_calls.py --text "$good" >/dev/null; ok $? "lint must accept (C11a): $good"; done
has SKILL.md 'One script per Bash call'
has stages/0-environment.md 'Each command below is its own Bash call'
has stages/3-build.md 'Code edits with the Edit / Write tools'
has stages/3-build.md 'only after the plan is approved, only on files inside the ticket worktree'
has stages/3-build.md 'shasum -a 256'
echo "# C11 commit gate: commits only via git-commit.sh after the staged stat; no stash; stop on EPERM; cleanup branch deletion is the user's"
has stages/7-commit-mr.md 'git diff --cached --stat` as its own call, shown in chat'
has stages/7-commit-mr.md '<skill dir>/scripts/git-commit.sh --session <id> -m'
hasnt "stages SKILL.md" 'If any pre-commit hook modified files'
has stages/3-build.md 'no `git stash`'
has stages/3-build.md 'do not retry in another spelling or with another command'
has stages/cancel.md '`git branch -d <branch>` is always a command for me'
has SKILL.md 'scripts/git-commit.sh --session <id>'
has README.md 'no Claude session in that repo commits outside the gate'
has README.md 'not the alias `pnpm i`, not via `npx` / `corepack`'
echo "# C11c2: turbo runs with a worktree-local --cache-dir (turbo shares the main checkout's cache from a git worktree)"
has stages/4-verify.md '--cache-dir=<this worktree>/.turbo/cache'
has profiles/node.md 'Git Worktree Cache Sharing'
echo "# C11c4: next/font in the sandbox is a known limit, never 'build ok'; the build is user-run evidence, no widening"
has stages/4-verify.md 'known sandbox limit: TLS check via trustd blocked (C11c4)'
has stages/4-verify.md 'It is never "build ok"'
has stages/4-verify.md 'executes the ticket'"'"'s code and package scripts (`next.config.*`, `postinstall`, plugins)'
has stages/4-verify.md 'git diff --stat <base>...HEAD'
has stages/4-verify.md 'A user-run paste never updates `verify.json`'
has init.md 'next/font/google'
has stages/4-verify.md 'evidence/<ID>/user-run-<check>.txt'
has stages/4-verify.md 'no settings change asked for (`allowedDomains`, `enableWeakerNetworkIsolation`'
echo "# C11c3: base-worktree.sh is bookkeeping (unsandboxed); a skill-script call holds no command substitution; _base installs run sandboxed"
for bad in '`<skill dir>/scripts/base-worktree.sh acquire T1 $(git merge-base HEAD main) --repo /r`' '`<skill dir>/scripts/base-worktree.sh acquire T1 `git merge-base HEAD main` --repo /r`' \
  '``<skill dir>/scripts/base-worktree.sh acquire T1 `git merge-base HEAD main` --repo /r``' $'```\n<skill dir>/scripts/plan-hash.sh T1 --repo `pwd`\n```' \
  $'```\n<skill dir>/scripts/plan-hash.sh T1 --repo $(pwd)\n```' '`X=$(<skill dir>/scripts/plan-hash.sh T1 --repo /r)`' '`scripts/base-worktree.sh release T1 --repo /r`'; do
  python3 tests/lint_script_calls.py --text "$bad" >/dev/null; [ $? = 1 ]; ok $? "lint must flag (C11c3): $bad"; done
for good in 'run `git merge-base HEAD main` (its own call), then `<skill dir>/scripts/base-worktree.sh acquire T1 <sha> --repo /r`' 'no `$( )` around `<skill dir>/scripts/plan-hash.sh T1`' \
  '`<skill dir>/scripts/env-keys.sh .env` prints `$NAME` keys' '``git log `x` ``, then `<skill dir>/scripts/plan-hash.sh T1`'; do
  python3 tests/lint_script_calls.py --text "$good" >/dev/null; ok $? "lint must accept (C11c3): $good"; done
has stages/4-verify.md '`<skill dir>/scripts/base-worktree.sh acquire <ID> <that sha> --repo <repo_root>`'
has stages/4-verify.md '`<skill dir>/scripts/setup-worktree.sh <repo_root> <repo_root>/.claude/worktrees/_base _base`'
has SKILL.md '`project-map-stale.sh`, `base-worktree.sh` (stage 4): the same spelling'
echo "# Code Mode not supported (experimental): stage 0 stops, documented next to the default-mode rule"
has SKILL.md 'Code Mode not supported (experimental)'
has README.md 'Code Mode not supported (experimental)'
has stages/0-environment.md 'printenv CLAUDE_CODE_EXPERIMENTAL_CODE_MODE'
has docs/plan.md 'Revisit Code Mode when it leaves experimental'
hasnt "SKILL.md init.md stages" '`scripts/[a-z]'
hasnt "SKILL.md init.md stages" 'python3 scripts/'
has stages/3-build.md '`CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `GEMINI.md`, `.cursorrules`, `.npmrc`'
has stages/3-build.md '`.vscode/` or `.github/`'
for good in 'run `<skill dir>/scripts/ticket-state.sh done T1`' '`<skill dir>/scripts/session-map.sh show`' '`<skill dir>/scripts/guard-write.sh diff`' 'git -C <wt> status' '`git branch -m a b`' 'from the worktree directory: `git push <remote> <branch>`' 'cd <wt>, then (second call) git push mirror x'; do python3 tests/lint_script_calls.py --text "$good" >/dev/null; ok $? "lint must accept: $good"; done
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
echo "# default mode, no auto mode (C11d), no plan mode (documented)"
has README.md 'auto mode is not supported'
has README.md 'CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 claude     # eval runs'
has README.md 'does not use plan mode'
has README.md 'which the guard blocks (dry runs 2 and 3)'
hasnt "README.md SKILL.md stages init.md" 'claude --permission-mode auto\|meant for auto mode'
hasnt "README.md SKILL.md stages" 'blocks ticket-file writes\|blocks writes to the ticket file'
has SKILL.md 'Auto mode is not supported'
has SKILL.md 'Do not use plan mode'
has SKILL.md 'which the guard blocks (dry runs 2 and 3)'
has SKILL.md 'its exit dialog switches the session to default mode'
has docs/plan.md 'HIGH PRIORITY – permission mode'
echo "# one state root (eval isolation): the default path is named only where DELIVER_TICKET_HOME is honoured"
has SKILL.md '${DELIVER_TICKET_HOME:-$HOME/.local/share/deliver-ticket}'
has SKILL.md 'This is the only place that names the default'
bad=$(python3 - <<'PY'
import os, re
rx = re.compile(r"\.local/share/deliver-ticket")
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
echo "# stage 1 rules changed after the first phase-6 pilot (2026-11-09)"
has stages/1-intake.md 'present in the ticket text or confirmed by the decision-maker'
has stages/1-intake.md 'never satisfy this item'
hasnt "stages SKILL.md templates" 'no source to draft from'
has stages/1-intake.md 'Order: bundling first'
has stages/1-intake.md 'decided before the DoR'
has stages/1-intake.md 'goes through the DoR \*\*on its own\*\*'
has docs/plan.md 'rules changed after the pilot'
echo "# questions in the final message; eval framing (after round 1)"
has stages/1-intake.md 'always go in your final message at the gate'
hasnt stages/1-intake.md 'question drafts)'
has docs/plan.md 'changed from B to C after the round 1 run'
has docs/plan.md 'review signal, not a hard gate'
has docs/plan.md 'Override log as the real-world measure'
echo "# questions confirm the drafts, follow the template (after round 1 review)"
has stages/1-intake.md 'Every question follows the template'
has stages/1-intake.md 'Drafts must be confirmed'
has stages/1-intake.md 'to confirm or correct them'
has stages/1-intake.md 'ask for them (DoR item 4)'
has docs/plan.md 'Round 1 is the baseline'
echo "# eval report"
has docs/eval-report-v0.1.md 'Round 1 is the baseline'
has docs/eval-report-v0.1.md 'Eval IDs collide with finished real tickets'
has docs/eval-report-v0.1.md '\$18.17'
echo "# install on a new machine"
has README.md '## Install on a new machine'
has README.md 'Clone to \*\*exactly\*\* `~/.claude/skills/deliver-ticket`'
has README.md 'scripts/install.sh'
has README.md 'denied in every project'
has README.md 'Unverified:'
has docs/plan.md 'Package as a Claude Code plugin'
has docs/plan.md 'CLAUDE_PLUGIN_ROOT'
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
