# Phase 5 checklist (needs the user)

Start of phase 5, in this order:
1. `scripts/install-hooks.sh diff` on the real `~/.claude/settings.json` -> show the whole diff -> user says yes -> `apply --confirmed` -> `selftest` -> new session.
   Rollback path: README.md "Emergency".
2. Init on `copilot-kit-training` (hooks active); stop point `local`; no push in that repo during the build.

Manual checks only the user can run (open items from plan section 13):
- [ ] **Desktop `WorktreeCreate`**: in the Desktop app, start a session with the Worktree toggle in a repo that has delivery state, then in a repo without. Does `worktree-create.sh` fire (path under `<repo>/.claude/worktrees/`, branch per naming rule / `worktree-<name>`)?
- [ ] **Interactive `EnterWorktree` prompt** (CLI and Desktop): does `EnterWorktree(name=<ID>)` ask for permission? If yes, note the wording and whether an allow rule can cover it.
- [ ] Dev-server watchers: does a dev server in the main checkout pick up `.claude/worktrees/**` changes?
- [ ] Auto-compaction: after a real auto-compact in a long ticket, does `session-start.sh` inject the re-orientation text?
- [ ] IDE extension (unsupported in v0.1): fallback = new session in the worktree.
