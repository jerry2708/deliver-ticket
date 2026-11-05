# Stage 3 - Build

Gate: tier A and B auto (no gate until the final review); **C: me after the stage (I read the diff)**. Work only inside the ticket worktree (path in the ticket file; call `EnterWorktree` with it if this session is elsewhere). Build only planned steps for non-waiting ACs.

## Rules
- **Code is the truth over `project.md`:** if a path, command, port or structure it states differs from what you see, trust the code, note the mismatch in the stage output, and fix that section at stage 8.
- **Bugs: failing test first**, at the lowest sensible level, failing for the right reason (show the failure). Then the fix.
- **Run lint + tests + build from the current worktree**, with the project's commands from config (`<ASK>` -> ask, never guess). Ports on the command line, never edit `.env`.
- **Never silence lint or type errors** (no `eslint-disable`, `@ts-ignore`, `any` to dodge a check).
- **Tests:** change an existing test only when an AC changes that behaviour - one line per changed test: `test -> AC -> reason`, collected for the review table. **Deleting or skipping a test goes to me.** A failing test is not "fixed" by weakening it.
- **Diff discipline:** if the diff grows well beyond the plan (new files not in the plan, a risk path touched, a much larger size), **stop and escalate**: say what changed, re-judge the 9 categories, tier only goes up, I confirm.
- A check that fails twice -> stop and tell me what you tried; do not loop.
- A requirement turns out ambiguous -> stop and ask; park the part.
- **Commits follow `commit_gate` in `guard.json` (CLAUDE.md "never commit without asking" wins):** tier A/B = `batched`: **make no commit in this stage**; the changes stay in the worktree and are committed once, at the stage-7 commit gate. Tier C (and soft mode) = `each`: ask before every commit (show the message and the staged diff). Conventional Commits unless config says otherwise; never bypass hooks (`--no-verify` is blocked). A commit that a pre-commit hook changed: see `7-commit-mr.md`.
- Env files: never read; key names only via `scripts/env-keys.sh <file>`. A ticket that needs a new key in `.env.example` gets a **manual step for me** in the stage output (edits to `.env*` are blocked).
- Nothing leaves the machine in this stage (no push, no MR).

## Leave
Update the ticket file: files changed, commits, test-change lines, deviations from the plan. `stage: 4`, `next: read stages/4-verify.md`. Tier C: stop and show the diff summary; wait for me.
