# Sandbox dry run: count the prompts that are not gates, v0.1 (`main`) vs v0.2 (sandbox)

Goal of milestone 1 (permission + stage lock): in default mode the user only answers the design gates. This run measures it: **the same ticket twice**,
once on `main` (v0.1, no sandbox), once on `v0.2` with the Bash sandbox, same project, same mode, same answers. It runs **interactively** in a Terminal tab
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
2. `scripts/probe-sandbox.sh <new scratch dir>` - the full pass (about 40 short Haiku runs). Expected: exit 0, or only rows you understand (`CHANGED` = this Claude Code
   behaves differently from the last probe: read the row before going on). `INCONCLUSIVE` rows: run them again with `--only`. A row that is not
   PASS names `raw/<case>-<mode>.json` in the scratch dir: the Bash calls, tool results and Haiku's reply of that run.
3. Record the result block: version, `summary:` line.

## B. Run 1 - v0.1 on `main`, no sandbox (the baseline)
1. In every project that has the sandbox on: `<skill dir>/scripts/install-hooks.sh project-sandbox-off --repo <main checkout> --confirmed` (safe switch, `docs/plan.md`).
2. `git checkout main` in the skill checkout; `<skill dir>/scripts/install-hooks.sh status`; if it differs, read `diff`, then `apply --confirmed` (your yes).
3. New session in the project clone: `claude` (default mode). Run the ticket: `/deliver-ticket <ID> <text>`; answer every gate as you would; stop point `local`.
4. Count with the sheet below while it runs. Do not fix or skip a prompt "to move on": answer it, write it down.

## C. Run 2 - v0.2 with the sandbox
1. `git checkout v0.2`; `<skill dir>/scripts/install-hooks.sh status` (it lists the missing user-level entries: sandbox keys, gate ask rules, gh / glab ask rules);
   read `diff`, then `apply --confirmed` in your own tab.
2. In the project clone: `<skill dir>/scripts/install-hooks.sh project-sandbox-diff --repo <main checkout> --domains <hosts> [--local-binding]`; read the whole diff
   (it names the git-ignore line if needed); then `project-sandbox-apply ... --confirmed [--add-exclude]`; `project-sandbox-status` must say `on`.
3. A **new** session (hooks and sandbox settings are read at start). Run the same ticket with the same answers.
4. Count with the same sheet.

## The counting sheet (one line per prompt that appeared; copy the table for each run)

| # | Stage | Command or tool (as shown in the prompt) | Design gate? | If not a gate: why did it prompt? |
|---|---|---|---|---|
| 1 | | | yes / no | not allowlisted / env prefix `FOO=` / `$VAR` or `$?` in the command / `cd x &&` / network host not allowed / excluded script without allow rule / unknown |

**Design gates** (these are the prompts that should remain): the ticket + tier confirmation, the plan, every stage in tier C, the final review, the commit gate,
a push (stop point permitting), `ticket-state.sh` close (one prompt per ticket), `guard-apply.sh`, `gh` / `glab` writes, a network host you did not allow.
Everything else is an **extra prompt**. A prompt in v0.1 that has no counterpart in v0.2 (or the reverse) goes in the notes.

Also write down, per run: stages that failed or needed a retry, anything that said `operation not permitted` / EPERM, `requires approval` that you did not expect,
and the wall time.

## D. Specific checks in run 2 (tick or note)
- [ ] Stage 0: `session-map.sh show` and `guard-write.sh verify` ran without a prompt; `verify` exit 3 (v0.1 `guard.json`) is a warning, not a stop.
- [ ] Stage 1b: `git branch -m <provisional> <final>` worked (a plain call from the worktree directory, no `-C`); the worktree was created; env links and the install ran.
- [ ] Stage 3-4: lint / test / build and the saved `evidence/<ID>/...` output ran without a prompt; the base-worktree comparison (`base-worktree.sh`) worked.
- [ ] If verify has a dev server: a sandboxed **client** (browser test, `curl`) reached a server started in a separate call (`--local-binding`); if not, note which tool and the exact message.
- [ ] The package install used only the allowed registry host; a host you did not allow gave one prompt or a `403`, not a silent success.
- [ ] Stage 7: exactly one prompt for the commit gate; a push attempt (if you try one at the end, to a scratch remote) gives exactly one prompt and the hook shows nothing odd.
- [ ] Stage 8: the `ticket-state.sh done` prompt appeared once; `session-map.sh pause` did not prompt.
- [ ] `cat` of a `.env*` file and an upper-case variant stayed blocked (the hooks), also with the sandbox on.
- [ ] `/deliver-ticket` in a second project while this ticket is open: the context line "still bound to ticket ..." appeared and nothing was bound.

## E. Result block to paste back
```
claude --version:
mode:
run 1 (v0.1, no sandbox):  gates N, extra prompts M, EPERM/failures K, minutes T
run 2 (v0.2, sandbox):     gates N, extra prompts M, EPERM/failures K, minutes T
extra prompts in run 2 (stage | command | why):
probe-sandbox summary line:
section D: ticked / notes:
```
**Success:** run 2 has only design gates (extra prompts 0, or each one explained and on a list to fix), no stage fails with EPERM, and no gate that exists in
run 1 is missing in run 2. Anything else becomes a finding with the exact prompt text, and the fix goes into the plan before the next real ticket.
