# Stage 8 - Record

Auto, after the final review. Writes only to the state dir.

1. **Ask me:** "anything that tripped us up?" Wait for the answer; add nothing of your own that I did not say or that the log does not show.
2. **Lessons** -> `lessons.md` (project: `~/.local/share/deliver-ticket/<project-key>/lessons.md`; global: `~/.local/share/deliver-ticket/lessons.md` only for things true across projects). One line each: `- [stage N] <what happened> -> <what to do> (<ID>, <date>)`. A lesson already there and seen again: bump a counter (`seen: 2`). 2+ times -> propose a change to the skill/config/CLAUDE.md/hook to me (wording generic, no client names). Do **not** edit the skill files from a ticket session; applying lessons is a separate session started in the skill folder.
3. **My corrections** as improvement signals (one line each, no judgement): tier changes (from -> to, my reason), plan edits, MR text rewrites, gates where I redirected you.
4. **Timestamps** per stage only if config `Time tracking` is on.
5. Ticket file: final state (`done` / `waiting for review` / `cancelled`), tier provisional vs confirmed, `stage: 8`, `next: none`. Worktree and branch stay; cleanup is listed in `cancel.md` and needs my confirmation.
