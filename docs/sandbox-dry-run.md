# Sandbox dry run: count the prompts that are not gates

Goal of milestone 1 (permission + stage lock): in default mode the user only answers the design gates. This run measures it: **one tier-B ticket** on `v0.2` with the Bash sandbox, in a separate project clone, in default mode. It runs **interactively** in a Terminal tab
(not in the skill-repo session, not `claude -p`: the gates need the user's answers across turns, and the TUI prompts are what is counted).

Fill in before starting:

| Field | Value |
|---|---|
| Project (a **separate clone**, not the working repo) | `<path>` |
| Ticket (a tier-B ticket whose stages are known) | `<ID and text>` |
| Stop point | `local` (no push in this run) |
| Mode | `default` (also `auto` as a second pair, optional) |
| Claude Code version (`claude --version`) | `<version>` |
| Package registry host(s) the verify commands need (`.npmrc`, else `registry.npmjs.org`; `playwright install` needs its CDN hosts) | `<hosts>` |
| Does verify need a dev server on localhost? (then `--local-binding`) | yes / no |

## A. Before anything (the user, own terminal tab; Claude only reads)
1. `git -C <skill checkout> status` clean; note the branch.
2. `scripts/probe-sandbox.sh <new scratch dir>` - the full pass (216 short Haiku runs at C11h, 205 cases, some in both modes; `--list | wc -l` prints the current number). Expected: exit 0, or only rows you understand (`CHANGED` = this Claude Code
   behaves differently from the last probe: read the row before going on). `INCONCLUSIVE` rows: run them again with `--only`. A row that is not
   PASS names `raw/<case>-<mode>.json` in the scratch dir: the Bash calls, tool results and Haiku's reply of that run.
3. Record the result block: version, `summary:` line.

## B. Reference baseline (no run for it)
The live skill checkout is never switched (every session's hooks follow it). Reference baseline = DRY-01 (2026-11-18, CC 2.1.311, no sandbox): **74 permission prompts**, counted in its transcript as `permissionDecision` entries with
`source: user_temporary` (C11h, 2026-11-27; the "about 50" in `~/.local/share/deliver-ticket/lessons.md` line 3 was an estimate). By command, 5 of them are gates in
today's sense (`approve-plan.sh`, `git commit`, `ticket-state.sh`, the project and the global `lessons.md` write) and 69 are not (28 Edit, 16 Read, 7 Write outside the
working dir; 13 Bash too-complex; others). DRY-02 (2026-11-27, CC 2.1.325, v0.2 at 0397e25, sandbox on): 11 prompts, 3 gates (`~/.cache/dt-probes/c11g-findings.md`).
DRY-03 (2026-11-27, CC 2.1.325, live skill 44604a8 = C11h, sandbox re-applied, same ticket text): **PASS** - 4 prompts, all gates (`~/.cache/dt-probes/c11g-dry03-result.md`; counts re-checked from the transcripts in C11i, `docs/plan.md` "C11g result"):

| | DRY-01 | DRY-02 | DRY-03 |
|---|---|---|---|
| prompts (`user_temporary`) | 74 (69 not gates) | 11 (8 not gates) | **4, all gates** |
| auto-allowed (`config`) | - | 147 | 147 (139 main + 8 reviewer) |
| EPERM | several | turbo, `.verify.json.tmp`, `.env`, husky | **only husky** (expected noise) |
| `verify-record.sh` | - | failed | **lint 0, test 0, `verify.json` recorded** |
| lock-trace listed | - | 1 | **0** |

DRY-03 follow-ups fixed in C11i: stage 4 now always offers the user-run build (it was skipped), the evidence dir exists from worktree setup, the `_base` env-link message names the sandbox.
How to count: every transcript line (main session and `subagents/*.jsonl`) whose `permissionDecision.source` is `user_temporary`.
Evidence: `~/.local/share/deliver-ticket/dryrun-ck-138e3ecd/` (ticket `tickets/DRY-01.md`, `evidence/DRY-01/`), transcript `~/.claude/projects/-Users-huynhminh--cache-dt-probes-dryrun-ck/262071df-0883-41c2-8e75-416c1e9ce440.jsonl`.
**Pass for this run: prompts == design gates, no EPERM.**
Optional later: a real v0.1 baseline from a separate clone with its own `CLAUDE_CONFIG_DIR` (unverified: may need a fresh login).

## C. The run (v0.2 with the sandbox)
1. `git -C <skill checkout> branch --show-current` says `v0.2`; the checkout is not switched for this run. `<skill dir>/scripts/install-hooks.sh status` (it lists the missing user-level entries: sandbox keys, gate ask rules, gh / glab ask rules);
   read `diff`, then `apply --confirmed` in your own tab.
2. In the project clone: `<skill dir>/scripts/install-hooks.sh project-sandbox-diff --repo <main checkout> --domains <hosts> [--local-binding]`; read the whole diff
   (it names the git-ignore line if needed); then `project-sandbox-apply ... --confirmed [--add-exclude]`; `project-sandbox-status` must say `on`.
3. A **new** session in the project clone (hooks and sandbox settings are read at start): `claude` (default mode). Run the ticket: `/deliver-ticket <ID> <text>`; answer every gate as you would; stop point `local`.
4. Count with the sheet below while it runs. Do not fix or skip a prompt "to move on": answer it, write it down.

## The counting sheet (one line per prompt that appeared)

| # | Stage | Command or tool (as shown in the prompt) | Design gate? | If not a gate: why did it prompt? |
|---|---|---|---|---|
| 1 | | | yes / no | not allowlisted / env prefix `FOO=` / `$VAR` or `$?` in the command / `cd x &&` / network host not allowed / excluded script without allow rule / unknown |

**Design gates** (these are the prompts that should remain): the ticket + tier confirmation, the plan, every stage in tier C, the final review, the commit gate (`git-commit.sh`),
a push (`git-push.sh`, stop point permitting), the plan approval (`approve-plan.sh`), `ticket-state.sh` close (one prompt per ticket), the stage-8 write of `lessons.md` (project and/or global; a gate since C11h: later runs read it), `guard-apply.sh`, `gh` / `glab` writes, a network host you did not allow. A tier-B run with stop point `local` and one lessons file written has **4 permission prompts that are gates**: `approve-plan.sh`, `git-commit.sh`, `ticket-state.sh`, the `lessons.md` write (DRY-02 had the first three plus 8 extra).
Everything else is an **extra prompt**. A prompt that DRY-01 had and this run does not (or the reverse) goes in the notes.

**Expected noise, not a failure:** `pnpm install` in a new worktree runs the repo's `prepare` script; husky's `git config core.hooksPath ...` then fails with
"could not lock config file" (the project sandbox denies writing `<git common dir>/config`, C11). The install finishes; Claude's commits run with the repo's hooks off
anyway (`git-commit.sh`). Count it under EPERM only if the install itself failed. (DRY-02, one occurrence.)

Also write down: stages that failed or needed a retry, anything that said `operation not permitted` / EPERM, `requires approval` that you did not expect,
and the wall time.

## D. Specific checks (tick or note)
- [ ] Stage 0: `session-map.sh show` and `guard-write.sh verify` ran without a prompt; `verify` exit 3 (v0.1 `guard.json`) is a warning, not a stop.
- [ ] Stage 1b: the worktree was created; env links and the install ran. The rename ran as `<skill dir>/scripts/git-rename.sh <provisional> <final>` from the worktree directory (`stages/1b-workspace.md` 2c; excluded script, no prompt expected; a plain `git branch -m` is blocked by the hook). Exit 3 / 4 (name exists) stops and asks you.
- [ ] Stage 2: the plan shows one line `plan hash <12 hex>` below it; after your yes, `approve-plan.sh <ID> --sha <that hash> ...` gives exactly one prompt (your approval). Before it, a write under the worktree is blocked ("approve the plan first"); after it, writes work. Edit the plan text afterwards: the next write is blocked again until a new approval.
- [ ] Stage 3-4: lint / test / build and the saved `evidence/<ID>/...` output ran without a prompt; the base-worktree comparison (`base-worktree.sh`) worked.
- [ ] Stage 4: the check commands run through the sandbox and, for `guard.json verify.on_push`, `verify-record.sh <ID>` ran as its own plain call (no prompt expected: sandboxed) and wrote `evidence/<ID>/verify.json`. A failing build that shows the next/font trustd signature is reported as "known sandbox limit" with the base comparison, never "build ok" (`stages/4-verify.md`); the user-run build needs your diff review first. Stage 4 offers it even when the base fails the same way (C11i): diff stat, exact command, "run it now, or skip?"; a skip shows as "unverified (user declined)" in the stage report and the AC table.
- [ ] If verify has a dev server: a sandboxed **client** (browser test, `curl`) reached a server started in a separate call (`--local-binding`); if not, note which tool and the exact message.
- [ ] The package install used only the allowed registry host; a host you did not allow gave one prompt or a `403`, not a silent success.
- [ ] Stage 7: each commit shows `git diff --cached --stat=10000 --no-renames` in chat as its own call, then exactly one prompt for `git-commit.sh` (your yes). A plain `git commit` is blocked. Exit 3 (`MISMATCH`) stops and shows `git show --stat --no-renames <sha>`. A push attempt (if you try one at the end, to a scratch remote) goes through `git-push.sh <remote> <branch>`, gives exactly one prompt, and the hook shows nothing odd.
- [ ] Stage 8: `lock-trace.sh <ID> ...` ran and its output was shown unchanged; note every listed line (exit 1) and every info line, with the call it names. Expected for a clean ticket: `lock trace: nothing listed`, or only lines you can explain. No prompt expected (read-only, sandboxed; not yet measured in a TUI run).
- [ ] Stage 8: the `ticket-state.sh done` prompt appeared once; `session-map.sh pause` did not prompt.
- [ ] `cat` of a `.env*` file and an upper-case variant stayed blocked (the hooks), also with the sandbox on.
- [ ] `/deliver-ticket` in a second project while this ticket is open: the context line "still bound to ticket ..." appeared and nothing was bound.

## E. Result block to paste back
```
claude --version:
mode:
run (v0.2, sandbox):       gates N, extra prompts M, EPERM/failures K, minutes T
extra prompts (stage | command | why):
probe-sandbox summary line:
section D: ticked / notes:
```
**Success:** the run has only design gates (extra prompts 0, or each one explained and on a list to fix), no stage fails with EPERM, and no design gate is missing.
Anything else becomes a finding with the exact prompt text, and the fix goes into the plan before the next real ticket.
