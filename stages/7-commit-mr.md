# Stage 7 - Commit + MR text

Gate by tier (A/B: the final review; **C: me at this stage**). Nothing goes past the **stop point** (per tier from `guard.json`; soft mode: `local`; CLAUDE.md wins): `local` -> `before-push` -> `draft-mr` -> `ready-mr`. **Merge is never automated** and is not an option here.

## Commit
Conventional Commits unless config says otherwise; commits end with the attribution lines the session was given. Final `git status` clean; show `git log --oneline <base>..HEAD`. Tier C and soft mode: ask before each commit.

## MR text - `templates/mr-description.md`, written to `evidence/<ID>/mr.md` (state dir)
- Every factual claim is checked against a diff hunk (**post-change** line numbers) before it goes in; claims you cannot check are removed. Known gaps are stated (unverified ACs, parked/waiting ACs, accepted gaps, tests changed with the reason).
- Link ACs to evidence by name; evidence files are not attached unless I checked them for client/personal data.
- **Delivery log** only if config has it on (default off for client projects): <= 5 lines or `<details>`: tier + reasons, auto vs human gates, checks run, answers/assumptions + who accepted - **roles, not names** (`PO`, `client`).
- MR text is for the reviewer: no tool chatter, no process notes about this skill.

## Up to the stop point
- `local`: stop. Show the commits and `mr.md`; tell me the exact commands for the later steps.
- `before-push`: stop before any push; show the exact `git push` command (named remote from config; a bare `git push` is blocked; `verify-on-push.sh` runs the verify commands first and may block).
- `draft-mr` / `ready-mr`: use the **adapter** from config (`adapters/gitlab-glab.md` or `adapters/manual.md`): check -> push (the allowed remote only) -> create (draft or ready). The push itself shows a permission prompt - that is my gate. Never `--force`, never `--no-verify`, never to a forbidden remote.
- Anything outward (push, MR create, comments) beyond the stop point -> stop and ask.

## Leave
Record in the ticket file: commits, MR URL if any, stop point reached, `state: waiting for review` (or `done` at `local`). `stage: 8`, `next: read stages/8-record.md`. Then the final-review gate: show the AC table, review table, security table, gaps; wait.
