# Stage 3 - Build

Gate: tier A and B auto (no gate until the final review); **C: me after the stage (I read the diff)**. Work only inside the ticket worktree (path in the ticket file; call `EnterWorktree` with it if this session is elsewhere). Build only planned steps for non-waiting ACs.

## Rules
- **Bugs: failing test first**, at the lowest sensible level, failing for the right reason (show the failure). Then the fix.
- **Run lint + tests + build from the current worktree**, with the project's commands from config (`<ASK>` -> ask, never guess). Ports on the command line, never edit `.env`.
- **Never silence lint or type errors** (no `eslint-disable`, `@ts-ignore`, `any` to dodge a check).
- **Tests:** change an existing test only when an AC changes that behaviour - one line per changed test: `test -> AC -> reason`, collected for the review table. **Deleting or skipping a test goes to me.** A failing test is not "fixed" by weakening it.
- **Diff discipline:** if the diff grows well beyond the plan (new files not in the plan, a risk path touched, a much larger size), **stop and escalate**: say what changed, re-judge the 9 categories, tier only goes up, I confirm.
- A check that fails twice -> stop and tell me what you tried; do not loop.
- A requirement turns out ambiguous -> stop and ask; park the part.
- Local commits: per tier setting (`local_commit_without_asking`). Tier C and soft mode: ask before every commit. Conventional Commits unless config says otherwise. After a commit, run `git status` - pre-commit hooks may have reformatted files; commit those too if the project's hooks produced them, never bypass hooks (`--no-verify` is blocked).
- Env files: never read; key names only via `scripts/env-keys.sh <file>`. A ticket that needs a new key in `.env.example` gets a **manual step for me** in the stage output (edits to `.env*` are blocked).
- Nothing leaves the machine in this stage (no push, no MR).

## Leave
Update the ticket file: files changed, commits, test-change lines, deviations from the plan. `stage: 4`, `next: read stages/4-verify.md`. Tier C: stop and show the diff summary; wait for me.
