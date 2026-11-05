# Stage 4 - Verify (definition of done)

Done = **every in-scope AC has evidence** + the **common DoD** from config (lint/build/tests green, related flows not broken, no secrets in diff/logs/evidence, risk areas reviewed). Verify checks only against these - nothing extra. Gate by tier: A layers 1-2 (auto); B layers 1-3 (I look at the real app/API once); C layers 1-4 + extras, me.

## 0. Environment for the real run (only what this ticket needs; ask before starting anything long-running)
- Ports: each port the run needs is free, or owned by **this** worktree (`lsof -i :<port>` plus the process's cwd). A server from another worktree or the main checkout on that port = wrong server; stop and tell me, don't kill it.
- Start dev servers with this ticket's ports on the command line (`PORT=<n> <cmd>`; port block in the ticket file). Never edit `.env`.
- Env **key names** the run needs are present: `scripts/env-keys.sh <file>` (names only); missing -> ask me to add; never print values.
- Model/provider config; signed-in browser state. A sign-in wall -> **I sign in**; you never type a password. Test identities: fake data only.

## 1. Automated (Claude)
lint, build, unit tests including new tests for changed logic; e2e if the project has it. All from the worktree. A failure -> back to stage 3 (twice -> stop).

## 2. AC -> evidence table (Claude drafts, I review) - `templates/ac-evidence.md`
One row per AC: how verified (test name / manual step), result, evidence link (`evidence/<ID>/...` in the state dir). Unverified ACs are marked **unverified**, never pass; waiting ACs **waiting**. Type the gaps: **missing** / **partial** / **contradicts**, plus **unrequested** (diff changes no AC asks for: justify or remove). "Done" in a task list or a commit message is not evidence.

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
Ticket file: the AC table, layer results, open gaps. Any `unverified`/`missing`/`contradicts` row -> not done: fix (stage 3) or tell me. `stage: 5`, `next: read stages/5-review.md`.
