# Stage 4 - Verify (definition of done)

Done = **every in-scope AC has evidence** + the **common DoD** from config (lint/build/tests green, related flows not broken, no secrets in diff/logs/evidence, risk areas reviewed). Verify checks only against these - nothing extra. Gate by tier: A layers 1-2 (auto); B layers 1-3 (I look at the real app/API once); C layers 1-4 + extras, me.

## 0. Environment for the real run (only what this ticket needs; ask before starting anything long-running)
- Ports: each port the run needs is free, or owned by **this** worktree (`lsof -i :<port>` plus the process's cwd). A server from another worktree or the main checkout on that port = wrong server; stop and tell me, don't kill it.
- Start dev servers with this ticket's ports on the command line (`PORT=<n> <cmd>`; port block in the ticket file). Never edit `.env`.
- Env **key names** the run needs are present: `scripts/env-keys.sh <file>` (names only); missing -> ask me to add; never print values.
- Model/provider config; signed-in browser state. A sign-in wall -> **I sign in**; you never type a password. Test identities: fake data only.

## 1. Automated (Claude)
lint, build, unit tests including new tests for changed logic; e2e if the project has it. All from the worktree. A failure -> triage below, then back to stage 3 (twice -> stop).
**Before you run anything, read `<state>/project.md` Commands and the `config.md` Verify notes.** Run lint, test and build **for every package or app the diff touches**, with its documented command (for a change under `apps/agent` in `copilot-kit-training`: `pnpm build:agent` and `pnpm --filter agent test`, not only `pnpm build`, which excludes the agent). A root command or a Turbo cache hit counts only for the packages it covers: say which. A documented command that is known to fail on the base (`project.md` / config say so) is not "build ok": run the pre-existing triage below, report the failure with the base commit, and never write that the build passed. Note that verify-on-push (`guard.json verify.on_push`) runs only the commands listed there; it is not a substitute for this layer.

### When a check fails: triage before touching code
1. **Is the failure caused by a stale fact?** A command, path, port or script name taken from `project.md` that does not exist or behaves differently (`command not found`, missing script, wrong port, file not found). If yes: verify the fact against its real source (`package.json`, config files, the code), fix that `project.md` section with the source, re-run the check **once**, note the mismatch in the stage report, and propose widening that section's `watch:` globs so `<skill dir>/scripts/project-map-stale.sh` would have caught it. If the wrong value is in `config.md` (a confirmed decision, for example a verify command) -> do **not** edit it; show me the evidence and ask.
2. **Pre-existing or regression?** Run the same command on the base, **never in the main checkout** (build and lint write `.next` / `dist` / `.turbo` there and can break a dev server I have running). Use the shared detached base worktree: `scripts/base-worktree.sh acquire <ID> $(git merge-base HEAD <base_branch>) --repo <repo_root>` (repo root and base branch from `guard.json`) prints `<repo>/.claude/worktrees/_base`, checked out detached at that commit, env files linked, dependencies installed. Run the same command there (`cd` into it for the run), save the output to `evidence/<ID>/base-<check>.txt`, then `scripts/base-worktree.sh release <ID> --repo <repo_root>`. Exit 3 (tracked changes in `_base`) or 4 (held by another ticket) -> stop and tell me. `_base` is reused by every ticket and never removed by the skill: removal only with my OK (listed at cleanup). Compare the two outputs: `scripts/compare-failures.py <base-output> <ticket-output> --root-base <dir> --root-ticket <dir>` (text heuristic; if the output format does not suit it, compare by hand and say which lines). Same failure on the base -> **pre-existing**: report it with the command and the base commit, do not fix it (CLAUDE.md "report pre-existing errors"), it is not a regression and does not block. A failure only on the ticket -> **regression**: fix it (stage 3). Never skip or loosen a check to get past either.

## 2. AC -> evidence table (Claude drafts, I review) - `templates/ac-evidence.md`
One row per AC: the **pass criterion copied verbatim from the AC** (never paraphrased), how verified (test name / manual step), result, evidence link (`evidence/<ID>/...` in the state dir). **Read the criterion strictly**: `pass` only if the observed outcome satisfies it as written. For an either/or criterion (for example "exactly that item is moved, or the assistant asks which one") say which branch happened; an outcome that is neither branch (for example one item moved after an ambiguous name, with no question asked) is `fail`. A criterion that is ambiguous is `unverified` plus a question for the decision-maker, never read in favour of pass. Unverified ACs are marked **unverified**, never pass; waiting ACs **waiting**. Type the gaps: **missing** / **partial** / **contradicts**, plus **unrequested** (diff changes no AC asks for: justify or remove). "Done" in a task list or a commit message is not evidence.

## 3. Real run (tier B and C)
Happy path once + the designed edge cases, by project type (config `Type`):
| Type | Real run | Evidence |
|---|---|---|
| Web FE | browser (Playwright MCP / browser pane) or a Playwright test | screenshot, network request, console |
| BE / API | call endpoints (`curl` / HTTP client) | request + response, status, logs |
| Job / worker | run with sample data | logs, DB state before/after |
| CLI / library | run the command / example | output |
| Mobile | simulator | screenshot |
Driving a browser is exploratory evidence (not repeatable, costs tokens); writing a Playwright test is repeatable. Prefer state checks over full-page snapshots. Stop after one repro of a bug that blocks every case. Evidence stays in the state dir; it may hold client or personal data - not attached to the MR without checking.

## 4. Regression (tier C; B if config says)
Flows near the change still work; scope from config `regression scope` (`<ASK>` -> ask me).

## Tier C extras
Error/edge cases; a **fresh-context AC check**: a subagent gets only the AC table, the evidence and the diff (not this conversation) and confirms each AC has real evidence (`templates/reviewer-verify.md`); short result back. AI-agent flows are run 3 times with state assertions. An exploratory run.

## Client-side cache of per-user data
If the project has user accounts and caches per-user data on the client (browser/device storage, persisted store): DoD item - on sign-out or user switch the cache is cleared or kept per user.

## Leave
If the real run showed `project.md` is wrong (code is the truth), fix that section now and note the mismatch.
Ticket file: the AC table, layer results, open gaps. Any `unverified`/`missing`/`contradicts` row -> not done: fix (stage 3) or tell me. `stage: 5`, `next: Read <skill dir>/stages/5-review.md`.
