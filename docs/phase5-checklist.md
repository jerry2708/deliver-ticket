# Phase 5 checklist

Phase 5 runs **interactively**, not through `claude -p`: the gates need the user's answers across turns.
Claude (in the skill-repo session) does part A; the user does parts B and C in a separate Terminal.app window and pastes the output back for review.

## A. Claude, in the skill-repo session (before the user starts anything)

1. `scripts/install-hooks.sh diff` on the real `~/.claude/settings.json`. Show the whole diff, all 6 hooks and all 6 permission rules verbatim. Wait for the user's yes. Nothing is written before that.
2. After the yes: `scripts/install-hooks.sh apply --confirmed` (it makes a backup next to the settings file), then `scripts/install-hooks.sh selftest`. Report both outputs. (2026-11-05 update: `WorktreeCreate` moved from user level to the project: removed from `~/.claude/settings.json` by a second `apply` with its own diff + yes, and registered by `project-apply --repo <main checkout>` after init wrote the state, again diff + yes.)
   Rollback: README.md "Emergency recovery" (`status`, `uninstall --confirmed`, restore the backup, manual edit).
3. Init on `/Users/huynhminh/Desktop/Work/copilot-kit-training` with hooks active: stop point `local`, no push in that repo during the build, and no other remote than `training-v2` if one is ever involved. Init asks the user its questions; Claude never answers them.
4. Claude says "ready". Hooks are read at session start, so part B must use a **new** session.

### Self-test A (part of init step 4), run once in a NEW session inside the project
Done once by the assistant with a fresh `claude -p` session in the repo on 2026-11-05 (both blocked). To see it yourself in Terminal.app:
1. `cd /Users/huynhminh/Desktop/Work/copilot-kit-training` and start `claude` (a new session; hooks are read at session start).
2. Type: `Run this Bash command exactly: echo DELIVER_TICKET_SELFTEST` - expected: blocked by `guard.sh` ("self-test marker ... this block is expected").
3. Type: `Write the file /Users/huynhminh/.claude/.deliver-ticket-selftest with the content x` - expected: blocked by `worktree-guard.sh` ("writes to ~/.claude/ ... only through scripts/install-hooks.sh"); `ls ~/.claude/.deliver-ticket-selftest` must say "No such file".
4. In the skill-repo session or any terminal: `~/.claude/skills/deliver-ticket/scripts/install-hooks.sh selftest --repo /Users/huynhminh/Desktop/Work/copilot-kit-training` must end with `selftest B: PASS`.
Not blocked in step 2 or 3 = soft mode: tell the assistant, do not start a ticket.

## B. The user, in Terminal.app (not the skill-repo session, not Desktop)

1. `cd /Users/huynhminh/Desktop/Work/copilot-kit-training`, start `claude` (new session).
2. **Retro #7** (tier C, ground truth in `evals/sample-tiers.md`, row 13):
   1. Type: `/deliver-ticket RETRO-7 Retro #7 - Prompt says productId, tool takes productNameOrId`.
      Expected: stage 0 table, then verdict `stop (DoR)`, no tier named, questions drafted, no worktree. If a tier is named or a worktree appears, stop and paste.
   2. Answer with the fixture (the one in `evals/sample-tiers.md`, "Re-run fixtures", row 13):
      goal "The agent's prompt describes the arguments the wishlist->cart tool really takes."; AC1 and AC2 as written there. Run `/deliver-ticket RETRO-7 <fixture text>`.
   3. Answer every gate yourself (tier C = every stage). Stop point stays `local`: if anything proposes a push or an MR, say no and note it.
3. **Retro #5** (tier B, row 11): same pattern, `/deliver-ticket RETRO-5 Retro #5 - purchase-plan-card crashes when the result has no checkout`, then the fixture for row 11.
4. Paste the whole terminal output of each ticket (and anything odd: a blocked command, a hook message, a question you did not expect) back into the skill-repo session. Claude reviews it against the stage files and `sample-tiers.md`; Claude does not answer gates and does not run the tickets itself.

What to watch and note while running (write the answer next to each):
- Did a hook block something it should not (or fail to block something it should)? Paste the message.
- Did the session map get written (`ls ~/.local/share/deliver-ticket/sessions/`) after stage 1b?
- Did the worktree appear under `copilot-kit-training/.claude/worktrees/<ID>`, with env symlinks and a free port block?
- Any step where the skill filled in a value instead of asking?
- Any `.env*` read, even by a search command? (`guard.sh` now blocks `grep -r/-R`, `rg --hidden`/`-uu` and `git grep` without an exclude when a `.env*` file is in reach; the phase-4 smoke showed Claude running `grep -r` over the repo once. Not caught: `find -exec grep`, other search tools.)

## C. Only the user can run (open items from plan section 13)

- [ ] **Desktop `WorktreeCreate`**: in the Desktop app, start a session with the Worktree toggle in a repo that has delivery state, then in a repo without. Does `worktree-create.sh` fire (path under `<repo>/.claude/worktrees/`, branch per naming rule / `worktree-<name>`)?
- [ ] **Interactive `EnterWorktree` prompt** (CLI and Desktop): does `EnterWorktree(name=<ID>)` ask for permission? If yes, note the wording and whether an allow rule can cover it.
- [ ] **UNVERIFIED: does `deny Read(**/.env*)` also stop the built-in Grep and Glob tools** (content search / listing that reaches `.env*`)? Try in a scratch repo with a dummy `.env.example` containing a fake key: Grep for the key name, Glob `**/.env*`. Note what comes back. If they are not stopped, `guard.sh` does not cover them either (it only sees Bash).
- [ ] **UNVERIFIED: stage 4 base run from a ticket session**: does the harness allow `scripts/base-worktree.sh acquire ...` (a skill script that runs git on the main repo inside) and then running a check with `cd .claude/worktrees/_base` from inside a ticket worktree, or does the worktree isolation prompt / refuse? Note the wording. Fallback: I run the base check by hand.
- [ ] Dev-server watchers: does a dev server in the main checkout pick up `.claude/worktrees/**` changes?
- [ ] Auto-compaction: after a real auto-compact in a long ticket, does `session-start.sh` inject the re-orientation text? (Stage 0-1 case too: with no worktree yet, it injects the single open intake ticket or lists several.)
- [ ] IDE extension (unsupported in v0.1): fallback = new session in the worktree.
