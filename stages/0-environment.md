# Stage 0 - Pre-flight (no changes)

Nothing is written in the repo or the state dir in this stage; it only reports. Run it at the start of every `/deliver-ticket <ticket>` (new, resume, rework). Gate: none, unless a check fails.

## Checks (report each as ok / warn / FAIL, one line)
1. **Claude Code version**: `claude --version` >= 2.1.311 (the minimum tested; the review discussion resumes a subagent with `SendMessage`). Below -> warn; the review then uses a new reviewer per round (`5-review.md`).
2. **Init found**: project key (SKILL.md section 3), then `~/.local/share/deliver-ticket/<project-key>/guard.json`. Missing -> FAIL: say the project is not initialised and offer `/deliver-ticket init`. Run `scripts/validate-guard.py <guard.json>`; exit not 0 -> FAIL, show its lines, stop.
3. **Config vs guard.json**: `config.md` or `config.local.md` newer than `guard.json` -> warn and offer to regenerate (init, re-run mode). `soft_mode: on` in config with `local` everywhere in `guard.json` stop points is expected, not drift.
4. **`<ASK>` left in config**: list the ones this ticket will need (verify commands, real-run tool, env files, regression scope, two test identities if a per-user server API or store is mapped in Risk). The stage that needs one stops and asks; never guess.
5. **Hook self-test, part A** (`init.md` step 4): a Bash call `echo DELIVER_TICKET_SELFTEST` must be blocked, and a Write of `~/.claude/.deliver-ticket-selftest` must be blocked. Then `scripts/install-hooks.sh status` (exit 0 = registered). Either part failing -> **soft mode** (SKILL.md section 5): tell me, record `mode: soft` in the ticket file at stage 1. If only the first call is not blocked right after install, ask me to start a new session and test there.
6. **Git**: inside a git repo; note whether this session is in the main checkout or in a ticket worktree. Uncommitted changes in the current directory -> warn (list `git status --short`, do not touch them).
7. **Parallel limit**: count `tickets/*.md` in the project state whose `state:` is `active` and that have a `worktree:`. More than `max_parallel.tier_bc` (tier B/C) or `max_parallel.total` (from `guard.json`) -> warn; I decide. Never refuse.
8. **CLAUDE.md** and `.claude/rules/` of the repo: read them now (they win over config, and the risk paths in them are always in the mapping). Report any conflict with config.

## Output
A short table: check, result, what it means for this ticket. Then continue to stage 1 (new ticket) or the recorded stage (resume). A FAIL in 2 stops here.

## Resume only
If the ticket file records a worktree and this session is not inside it, call `EnterWorktree` with that `path` (under `<repo>/.claude/worktrees/`) before check 5, then run the checks again from inside it.
