# Stage 7 - Commit + MR text

Gate by tier (**A/B: the commit gate below, one yes for the whole set; C: me before every commit**). Nothing goes past the **stop point** (per tier from `guard.json`; soft mode: `local`; CLAUDE.md wins): `local` -> `before-push` -> `draft-mr` -> `ready-mr`. **Merge is never automated** and is not an option here.

## Commit
Conventional Commits unless config says otherwise; commits end with the attribution lines the session was given.
- **Tier A/B (`commit_gate: batched`) - commit gate:** nothing is committed yet. Group the changes into the planned commits (one per plan step or chunk; files shared by two steps go in one commit; no hunk splitting). Show me (1) the diff (`git diff <base>`, stat + the hunks), (2) every planned commit: message, files, the AC(s) it serves. **One yes covers the whole set**; any change request -> adjust and show again. Only then create the commits.
- **Tier C and soft mode (`each`):** ask before every commit (message + staged diff).
- **How each commit is made** (the project sandbox denies the git ref store, so a plain `git commit` cannot land, and the hook blocks it in a ticket worktree): from the worktree directory, (1) `git add <the files of this commit>`, (2) **`git diff --cached --stat` as its own call, shown in chat** (the permission prompt shows only the command, not what is staged), (3) the next call, `<skill dir>/scripts/git-commit.sh --session <id> -m "<message>"` (or `-F <message file>`). Its prompt is my yes. It refuses unless the plan is approved and HEAD is the ticket's recorded branch; it logs the commit, the staged tree and the staged file list to `delivery.log` (stage 8 lock-trace compares them with the stat you showed). No `--amend`, no `-a`, no pathspecs: a wrong commit is fixed by a new one.
- The repo's own git hooks (pre-commit, commit-msg) do **not** run on these commits (`core.hooksPath=/dev/null`, as for the push): what they check belongs in the stage-4 checks / `verify.on_push`.
- Final `git status` clean; show `git log --oneline <base>..HEAD`.

## MR text - `templates/mr-description.md`, written to `evidence/<ID>/mr.md` (state dir)
- Every factual claim is checked against a diff hunk (**post-change** line numbers) before it goes in; claims you cannot check are removed. Known gaps are stated (unverified ACs, parked/waiting ACs, accepted gaps, tests changed with the reason).
- Link ACs to evidence by name; evidence files are not attached unless I checked them for client/personal data.
- **Delivery log** only if config has it on (default off for client projects): <= 5 lines or `<details>`: tier + reasons, auto vs human gates, checks run, answers/assumptions + who accepted - **roles, not names** (`PO`, `client`).
- MR text is for the reviewer: no tool chatter, no process notes about this skill.

## Up to the stop point
- `local`: stop. Show the commits and `mr.md`; tell me the exact commands for the later steps.
- `before-push`: stop before any push; show the exact push command `<skill dir>/scripts/git-push.sh <remote> <branch>` (run from the worktree directory; named remote from config; a plain `git push` is blocked by the hook; the script pushes `HEAD` to `<branch>`, validates its own arguments, runs git with the repo's own hooks off and checks the stage 4 record `<state>/evidence/<ID>/verify.json` for the HEAD tree and blocks when it is missing, failed or stale - run `<skill dir>/scripts/verify-record.sh <ID> --guard <state>/guard.json` again after any new commit; the result you show me before the push prompt is that record).
- `draft-mr` / `ready-mr`: use the **adapter** from config (`adapters/gitlab-glab.md` or `adapters/manual.md`): check -> push (the allowed remote only) -> create (draft or ready). The push itself shows a permission prompt - that is my gate. Never `--force`, never `--no-verify`, never to a forbidden remote.
- Anything outward (push, MR create, comments) beyond the stop point -> stop and ask.

## Leave
Record in the ticket file: commits, MR URL if any, stop point reached, `state: waiting for review` (or `done` at `local`). `stage: 8`, `next: Read <skill dir>/stages/8-record.md`. Then the final-review gate: show the AC table, review table, security table, gaps; wait.
