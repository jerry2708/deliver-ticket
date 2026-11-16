# Stage 7 - Commit + MR text

Gate by tier (**A/B: the commit gate below, one yes for the whole set; C: me before every commit**). Nothing goes past the **stop point** (per tier from `guard.json`; soft mode: `local`; CLAUDE.md wins): `local` -> `before-push` -> `draft-mr` -> `ready-mr`. **Merge is never automated** and is not an option here.

## Commit
Conventional Commits unless config says otherwise; commits end with the attribution lines the session was given.
- **Tier A/B (`commit_gate: batched`) - commit gate:** nothing is committed yet. Group the changes into the planned commits (one per plan step or chunk; files shared by two steps go in one commit; no hunk splitting). Show me (1) the diff (`git diff <base>`, stat + the hunks), (2) every planned commit: message, files, the AC(s) it serves. **One yes covers the whole set**; any change request -> adjust and show again. Only then create the commits.
- **Tier C and soft mode (`each`):** ask before every commit (message + staged diff).
- **If any pre-commit hook modified files** (compare what you staged with `git show --stat HEAD` / `git status --short` after the commit; no such hook = nothing to do): the commit that counts is the post-hook one. Commit the hook's changes the way the project's hooks produce them (never bypass), record `verified at <sha>` of the post-hook commit in the AC -> evidence table, and **re-run the stage-4 automated checks on that commit**; a failure goes back to stage 3.
- Final `git status` clean; show `git log --oneline <base>..HEAD`.

## MR text - `templates/mr-description.md`, written to `evidence/<ID>/mr.md` (state dir)
- Every factual claim is checked against a diff hunk (**post-change** line numbers) before it goes in; claims you cannot check are removed. Known gaps are stated (unverified ACs, parked/waiting ACs, accepted gaps, tests changed with the reason).
- Link ACs to evidence by name; evidence files are not attached unless I checked them for client/personal data.
- **Delivery log** only if config has it on (default off for client projects): <= 5 lines or `<details>`: tier + reasons, auto vs human gates, checks run, answers/assumptions + who accepted - **roles, not names** (`PO`, `client`).
- MR text is for the reviewer: no tool chatter, no process notes about this skill.

## Up to the stop point
- `local`: stop. Show the commits and `mr.md`; tell me the exact commands for the later steps.
- `before-push`: stop before any push; show the exact `git push` command (plain, run from the worktree directory, never `git -C`; named remote from config; a bare `git push` is blocked; `verify-on-push.sh` does not run the verify commands any more: it checks the stage 4 record `<state>/evidence/<ID>/verify.json` for the HEAD tree and blocks when it is missing, failed or stale - run `<skill dir>/scripts/verify-record.sh <ID> --guard <state>/guard.json` again after any new commit; the result you show me before the push prompt is that record).
- `draft-mr` / `ready-mr`: use the **adapter** from config (`adapters/gitlab-glab.md` or `adapters/manual.md`): check -> push (the allowed remote only) -> create (draft or ready). The push itself shows a permission prompt - that is my gate. Never `--force`, never `--no-verify`, never to a forbidden remote.
- Anything outward (push, MR create, comments) beyond the stop point -> stop and ask.

## Leave
Record in the ticket file: commits, MR URL if any, stop point reached, `state: waiting for review` (or `done` at `local`). `stage: 8`, `next: Read <skill dir>/stages/8-record.md`. Then the final-review gate: show the AC table, review table, security table, gaps; wait.
