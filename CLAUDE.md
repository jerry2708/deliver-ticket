# CLAUDE.md - rules for any session working in this repo (the deliver-ticket skill)

These hold in every session, whatever the task. The design is in `docs/plan.md` (section 13 "Build decisions" has the full list of build constraints).

## Deleting, moving, temp files
- **Never delete or move anything without asking first: no `rm`, `rmdir`, `mv`, `git clean`, `git branch -D`, `git worktree remove`, no tool-based deletion, for ANY file or directory** - including your own test artifacts, scratch repos, `*.bak` files and temp files. List what exists (the list lives in `~/.local/share/deliver-ticket/build-cleanup-list.md`) and let the user decide. Three unasked deletions already happened; do not make a fourth.
- **Temporary files go only into the session scratchpad directory** named in the system prompt. Never `/tmp`, never `/private/tmp` outside the scratchpad, never next to the files you edit. Tests take a new scratch directory as an argument and never delete it.
- No `sed -i.bak` / `perl -i.bak`: edit with the Edit tool, or `sed -i ''`, so that no stray file is created.
- The skill's own scripts rename files by design (`pending-ticket.sh take` -> `.consumed`, `ticket-state.sh reopen` -> `.reopened-<ts>`, atomic `os.replace` of a file they just wrote); that is product behaviour documented in the script, not a licence for your own `mv`.

## Other standing rules (details in `docs/plan.md` section 13)
- Ask before every commit; Conventional Commits; no push in this repo or in the test project unless told; no force push, no `--no-verify`, no merge.
- `~/.claude/settings*` only through `scripts/install-hooks.sh`, after the exact diff and the user's yes, with a backup.
- Never read or print `.env*` contents (key names only, via `scripts/env-keys.sh`).
- Every hook change is tested against a session with an open ticket **and** one without (README "Extending").
- Report what you did not verify; label unverified items.
