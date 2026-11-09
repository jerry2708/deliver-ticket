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

0. **Precondition for every eval run (answer key out of the project):** move only the `deliver-ticket-*.md` files out of `copilot-kit-training` yourself (`docs/training-v2/deliver-ticket-sample-tiers.md` and its siblings). `day-15.md` and `capstone/tickets.md` stay on purpose: the run then also checks that the rule "repo notes are not searched for the ticket" (`stages/1-intake.md`, Input rules) held. Each eval run uses a **fresh session** (a session that has seen the answer key or an earlier run is contaminated).
1. `cd /Users/huynhminh/Desktop/Work/copilot-kit-training`, start `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 claude` (new session; eval runs start with auto memory off so the project's `MEMORY.md` does not reach the session; see the one-time check below, and do not edit any memory file).
2. **Retro #7** (tier C, ground truth in `evals/sample-tiers.md`, row 13):
   1. Type: `/deliver-ticket RETRO-7 Retro #7 - Prompt says productId, tool takes productNameOrId`.
      Expected: stage 0 table, then verdict `stop (DoR)`, no tier named, questions drafted, no worktree. If a tier is named or a worktree appears, stop and paste.
   2. Answer with the fixture (the one in `evals/sample-tiers.md`, "Re-run fixtures", row 13):
      goal "The agent's prompt describes the arguments the wishlist->cart tool really takes."; AC1 and AC2 as written there. Run `/deliver-ticket RETRO-7 <fixture text>`.
   3. Answer every gate yourself (tier C = every stage). Stop point stays `local`: if anything proposes a push or an MR, say no and note it.
3. **Retro #5** (tier B, row 11): same pattern, `/deliver-ticket RETRO-5 Retro #5 - purchase-plan-card crashes when the result has no checkout`, then the fixture for row 11.
4. Paste the whole terminal output of each ticket (and anything odd: a blocked command, a hook message, a question you did not expect) back into the skill-repo session. Claude reviews it against the stage files and `sample-tiers.md`; Claude does not answer gates and does not run the tickets itself.

After each run (rule check, record it in the run log below): `scripts/transcript-reads.py ~/.claude/projects/-Users-huynhminh-Desktop-Work-copilot-kit-training/<session id>.jsonl --ticket RETRO-7 --title 'Retro #7' --title retro` lists every Read / Grep / Glob / Bash call that touches `docs` (with or without the slash) and every search for the ticket ID / title words that is not restricted to code paths (a `git grep` or `grep -r .` over the whole repo counts; `git log --grep` and code-path searches do not). Expected: none that searches for the ticket. Allowed and to be noted but not counted as a violation: technical docs by API or symbol (for example `node_modules/next/dist/docs/`), knowledge sources opened by path from `project.md`. Second check for retro #7: the run must find `moveWishlistItemToCartTool` at `apps/web/src/tools/use-commerce-cart-tools.tsx:223` (it takes `productNameOrId`) with an uncut search (SKILL.md section 6).

**One-time check before phase 6 (auto memory off for eval runs). DONE 2026-11-09: `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` verified (result 0 / control 5 and 17, below).** Procedure: start a throw-away session with `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 claude` in `copilot-kit-training`, send one harmless prompt (for example `say hi`), exit, then count in its transcript `~/.claude/projects/-Users-huynhminh-Desktop-Work-copilot-kit-training/<session id>.jsonl`: `grep -c -e 'MEMORY.md' -e 'deliver-ticket-archive' <that file>` must print **0**. Control: the same grep on a normal session transcript (for example dry run 2, `8141a8cf-afa5-493a-85e1-f5acc96ffa49.jsonl`, where the memory index appears) prints more than 0. Record both numbers here: result **0** (session 7c556492, `claude -p` with the variable) / control **5** (session 94c337a3, `claude -p`, same prompt, without the variable; `MEMORY.md` loaded as `"type":"AutoMem"`) and **17** (interactive dry run 2, 8141a8cf). `'deliver-ticket-archive'` = 0 in the control too, because the memory index was reworded (option A). (The memory index line is yours to reword; no memory file is touched by the skill.)

**Dry run 3 checks for the backlog fixes** (look at the transcript and the state dir): (1) the branch was renamed with `git -C <worktree> branch -m` from `work/retro-7` to the full name before the first commit; (2) no Bash call of the form `cd <skill dir> && cat ...` (`grep -c 'cd .*deliver-ticket' <transcript>` counts only inputs you read by eye); (4) the AC table has the verbatim pass-criterion column and an either/or AC passes only through the branch that happened; (6) `ls ~/.local/share/deliver-ticket/copilot-kit-training-cd02feca/evidence/<ID>/stage3-*` lists every check stage 3 reported; (7) stage 4 layer 1 names the build command per affected package and does not write "build ok" for a command that fails on the base; (5) a coach session that `cd`s into the worktree gets the "cd out of the worktree" hint in the block message.

What to watch and note while running (write the answer next to each):
- Did a hook block something it should not (or fail to block something it should)? Paste the message.
- Did the session map get written (`ls ~/.local/share/deliver-ticket/sessions/`) after stage 1b?
- Did the worktree appear under `copilot-kit-training/.claude/worktrees/<ID>`, with env symlinks and a free port block?
- Any step where the skill filled in a value instead of asking?
- Any `.env*` read, even by a search command? (`guard.sh` now blocks `grep -r/-R`, `rg --hidden`/`-uu` and `git grep` without an exclude when a `.env*` file is in reach; the phase-4 smoke showed Claude running `grep -r` over the repo once. Not caught: `find -exec grep`, other search tools.)

### Run log
| Run | Session | Result | Rule check (docs/ reads) | Notes |
|---|---|---|---|---|
| RETRO-7, dry run 1 (2026-11-06) | e5ee55ac | `stop (DoR)` = ground truth row 13 (missing goal + testable AC); no tier, worktree or repo change; bind fired on a typed prompt (payload in the expanded `<command-name>` / `<command-args>` form); self-test A blocked both; `pause` + `delivery.log` line correct; guard caught `grep -r` without a `.env` exclude and `$VAR` write paths, the model recovered | **violated**: searched `docs/training-v2` for "retro" and read `deliver-ticket-sample-tiers.md` (answer key), disclosed it; run contaminated | The first version of `transcript-reads.py` listed only lines 100 and 108; it now also lists lines 90, 94 and 97 (`ls docs`, `grep -rn "RETRO-7\|Retro #7" … .`, `git grep -n -e 'RETRO-7' -e 'Retro #7'`), the real commands are test cases. The first `transcript-reads.py` listed only lines 100 and 108; it now also lists 90, 94 and 97 (`ls docs`, `grep -rn "RETRO-7\|Retro #7" … .`, `git grep -n -e 'RETRO-7' -e 'Retro #7'`), and those real commands are its test cases. `\| head -20` cut the grep and hid `moveWishlistItemToCartTool` (`use-commerce-cart-tools.tsx:223`); fixes: intake rule, no-truncation rule, self-test pre-announce line, absolute-path line |
| RETRO-7, dry run 2 | 8141a8cf | 0 flagged after 9fec609 (2 errored attempts, lines 92/96, not counted); the earlier 52 came partly from my too-broad --title wishlist call | 0 real violations (52 flags were tool noise) | |
| RETRO-5, dry run 3 (tier B) | | | | |

## C. Only the user can run (open items from plan section 13)

- [ ] **Desktop `WorktreeCreate`**: in the Desktop app, start a session with the Worktree toggle in a repo that has delivery state, then in a repo without. Does `worktree-create.sh` fire (path under `<repo>/.claude/worktrees/`, branch per naming rule / `worktree-<name>`)?
- [ ] **Interactive `EnterWorktree` prompt** (CLI and Desktop): does `EnterWorktree(name=<ID>)` ask for permission? If yes, note the wording and whether an allow rule can cover it.
- [ ] **UNVERIFIED: does `deny Read(**/.env*)` also stop the built-in Grep and Glob tools** (content search / listing that reaches `.env*`)? Try in a scratch repo with a dummy `.env.example` containing a fake key: Grep for the key name, Glob `**/.env*`. Note what comes back. If they are not stopped, `guard.sh` does not cover them either (it only sees Bash).
- [ ] **UNVERIFIED: stage 4 base run from a ticket session**: does the harness allow `scripts/base-worktree.sh acquire ...` (a skill script that runs git on the main repo inside) and then running a check with `cd .claude/worktrees/_base` from inside a ticket worktree, or does the worktree isolation prompt / refuse? Note the wording. Fallback: I run the base check by hand.
- [ ] **Bind hook with a typed prompt** (CLI and Desktop): after typing `/deliver-ticket RETRO-7 ...`, does `~/.local/share/deliver-ticket/sessions/<session id>` appear with `project=` and `ticket=RETRO-7`? (`ls -t ~/.local/share/deliver-ticket/sessions | head -3`; stage 0 check 10 also reports it.) Verified only with `claude -p`.
- [ ] **Subagent and binding**: when the reviewer subagent runs inside a ticket session, is it still covered (does its hook payload carry the parent's session id)? Reviewers are read-only, so the risk is low; note the result.
- [ ] A session in `copilot-kit-training` with no `/deliver-ticket` (your coaching session): can it write a file in the main checkout, and commit with husky, as before the skill? (It must.) A ticket session must still be blocked from the main checkout.
- [ ] Dev-server watchers: does a dev server in the main checkout pick up `.claude/worktrees/**` changes?
- [ ] Auto-compaction: after a real auto-compact in a long ticket, does `session-start.sh` inject the re-orientation text? (Stage 0-1 case too: with no worktree yet, it injects the single open intake ticket or lists several.)
- [ ] IDE extension (unsupported in v0.1): fallback = new session in the worktree.
