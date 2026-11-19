# Stage 3 - Build

Gate: tier A and B auto (no gate until the final review); **C: me after the stage (I read the diff)**. Work only inside the ticket worktree (path in the ticket file; call `EnterWorktree` with it if this session is elsewhere). Build only planned steps for non-waiting ACs.

## Rules
- **Code is the truth over `project.md`:** if a path, command, port or structure it states differs from what you see, trust the code, note the mismatch in the stage output, and fix that section at stage 8.
- **Bugs: failing test first**, at the lowest sensible level, failing for the right reason (show the failure). Then the fix.
- **Run lint + tests + build from the current worktree**, with the project's commands from config (`<ASK>` -> ask, never guess). Ports on the command line, never edit `.env`.
- **Save the output of every check you run and report** (tests, lint, build, a mutation check, a before/after run) to `evidence/<ID>/stage3-<check>.txt` in the state dir: the command and its exit code on the first line, then the full output. List the paths in the ticket file. A check you report without a saved file is not reported as done (the stage-4 reviewer flags it).
- **Code edits with the Edit / Write tools**, inside the ticket worktree: they need no prompt there (project-apply's allow rule; the plan lock and the hooks still apply). Bash runs commands; it does not write source files (no `sed -i`, `echo >`, `cat <<EOF >` on code). An edit under the worktree's `.claude/`, `.git`, `.gitmodules`, `.mcp.json`, `.husky/`, `.vscode/` or `.github/`, or anywhere in `.claude/worktrees/_base`, asks me first (they configure Claude Code, git, MCP servers, git hooks, the editor or CI): say why the ticket needs it. The same for agent instruction files and npm config at any depth (`CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `GEMINI.md`, `.cursorrules`, `.npmrc`): they steer later sessions or installs, so name the reason with the edit.
- **Mutation checks** (break the code on purpose to show a test catches it): only after the plan is approved, only on files inside the ticket worktree, run by a script you write into this session's scratchpad (never into the worktree or the repo). Record `shasum -a 256` of every file you mutate before the first mutation; after the run restore them and compare (not `git diff --quiet`: the worktree holds the ticket's uncommitted changes). Every hash equal -> say so with the two hash lists in `evidence/<ID>/stage3-mutation.txt`; any difference -> stop and tell me.
- **Never silence lint or type errors** (no `eslint-disable`, `@ts-ignore`, `any` to dodge a check).
- **Tests:** change an existing test only when an AC changes that behaviour - one line per changed test: `test -> AC -> reason`, collected for the review table. **Deleting or skipping a test goes to me.** A failing test is not "fixed" by weakening it.
- **Diff discipline:** if the diff grows well beyond the plan (new files not in the plan, a risk path touched, a much larger size), **stop and escalate**: say what changed, re-judge the 9 categories, tier only goes up, I confirm.
- A check that fails twice -> stop and tell me what you tried; do not loop.
- A requirement turns out ambiguous -> stop and ask; park the part.
- **Commits follow `commit_gate` in `guard.json` (CLAUDE.md "never commit without asking" wins):** tier A/B = `batched`: **make no commit in this stage**; the changes stay in the worktree and are committed once, at the stage-7 commit gate. Tier C (and soft mode) = `each`: ask before every commit (show the message and the staged diff). Conventional Commits unless config says otherwise; never bypass hooks (`--no-verify` is blocked). A commit that a pre-commit hook changed: see `7-commit-mr.md`.
- Env files: never read; key names only via `scripts/env-keys.sh <file>`. A ticket that needs a new key in `.env.example` gets a **manual step for me** in the stage output (edits to `.env*` are blocked).
- Nothing leaves the machine in this stage (no push, no MR).

## Leave
Update the ticket file: files changed, commits, test-change lines, deviations from the plan, the paths of the saved check outputs (`evidence/<ID>/stage3-*.txt`). `stage: 4`, `next: Read <skill dir>/stages/4-verify.md`. Tier C: stop and show the diff summary; wait for me.
