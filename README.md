# deliver-ticket (personal skill)

`/deliver-ticket init | <ticket-id|file> | <ID> cancel`. Run it only by typing it. Design rationale: `docs/plan.md`. `<state root>` below = `$DELIVER_TICKET_HOME`, default `~/.local/share/deliver-ticket` (defined in `SKILL.md` section 3).

## Permission mode: launch in auto mode, no plan mode
The skill is meant for **auto mode**: the gates are the skill's, the safety is the hooks'. A skill cannot set the mode. In Claude Code 2.1.311 auto is granted only from user or policy settings or the `--permission-mode` flag (a project or local `defaultMode: "auto"` is ignored; verified in the 2.1.311 binary: "only policy/user/flag settings may grant auto mode"). Launch with:

```
claude --permission-mode auto
CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 claude --permission-mode auto     # eval runs
```

The skill does not use plan mode (`EnterPlanMode` / `ExitPlanMode`): plan mode writes its plan under `~/.claude/plans/`, which the guard blocks (dry runs 2 and 3); its exit dialog switches the session to default mode; its "approved" came back although the user had seen no plan (dry run 3), so it is never the user's approval. Stage 2 writes the plan into the ticket file and stops at the gate.

## Install on a new machine
Requirements: Claude Code (tested on **2.1.311**; stage 0 warns below it), `git`, `python3`, `bash`; `glab` is optional (only for stop points that create a GitLab MR).

1. Clone to **exactly** `~/.claude/skills/deliver-ticket` (the hooks and `SKILL.md` use that path): `git clone <this repo's URL> ~/.claude/skills/deliver-ticket` (the clone path matters, not where it comes from).
2. Run `~/.claude/skills/deliver-ticket/scripts/install.sh`. It checks the tools and the clone path, prints the `~/.claude/settings.json` diff, asks y/n, and only on `y` runs `install-hooks.sh apply --confirmed` (a backup is made) and `install-hooks.sh status`. By hand it is the same three steps: `scripts/install-hooks.sh diff`, then `apply --confirmed`, then `status`.
3. Per project, in its **main checkout**, start Claude Code (`claude --permission-mode auto`, see above) and run `/deliver-ticket init`. Init asks its questions and writes the project's state under the state root (`<state root>/<project-key>/`), not into this repo and not into the client repo; the per-project `WorktreeCreate` and `UserPromptSubmit` hooks go into `<repo>/.claude/settings.local.json` through `install-hooks.sh project-apply` (diff and your yes first).
4. The user-level rules that `apply` adds are global: **`glab mr merge` and `gh pr merge` are denied in every project** (merge in the GitLab UI), and pushes / MR creation ask first. See "Global permission rules" below.

Update: `git pull` in the clone, then `scripts/install-hooks.sh status`; it says if the registered hooks or rules differ from this version (then `diff`, your yes, `apply --confirmed`).

**Unverified:** whether copying a project's state dir (`<state root>/<project-key>/`) to another machine works. The key is derived from the main checkout's absolute path and `guard.json` holds absolute paths, so it should only work when the checkout sits at the same path (inference, not tested); otherwise run `/deliver-ticket init` again.

## Emergency: a hook blocks every session

The hooks are registered in `~/.claude/settings.json` (user level). If a hook bug blocks all work, run these **from a normal terminal** (not from inside Claude Code):

```sh
# 1. see what is installed
~/.claude/skills/deliver-ticket/scripts/install-hooks.sh status

# 2a. remove exactly what `apply` added (hooks of this skill + the permission rules apply added; nothing else)
~/.claude/skills/deliver-ticket/scripts/install-hooks.sh uninstall            # dry run: prints the diff
~/.claude/skills/deliver-ticket/scripts/install-hooks.sh uninstall --confirmed # writes, with a backup

# 2b. or restore a backup (every apply/uninstall makes one next to the settings file)
ls -t ~/.claude/settings.json.bak-deliver-ticket-*
cp ~/.claude/settings.json.bak-deliver-ticket-<timestamp> ~/.claude/settings.json

# 2c. the per-project WorktreeCreate hook (lives in <repo>/.claude/settings.local.json, gitignored)
~/.claude/skills/deliver-ticket/scripts/install-hooks.sh project-uninstall --repo <main checkout> --confirmed   # backup goes to the project's state dir

# 2d. one session is stuck as "bound" (e.g. a ticket that cannot be closed properly): from a normal terminal, remove that session's map
#     <state root>/sessions/<session id>   (it only records which ticket the session works on)

# 3. last resort, no scripts: delete the entries whose "command" contains
#    /.claude/skills/deliver-ticket/hooks/ from ~/.claude/settings.json (and from <repo>/.claude/settings.local.json) by hand
```

The hooks do nothing in a repo without delivery state (`<state root>/<project-key>/guard.json`), except that a Write / Edit or shell write whose text names the state root's directory name is still checked against the protected state (`sessions/`, `closed/`, `delivery.log`); known limits: globs, paths built without the root's name, symlinks made earlier, interpreters. A delete / move verb (`rm`, `rmdir`, `unlink`, `shred`, `mv`) also starts that check, so deleting a parent of the state root is caught there too.

**Protected state (every session, every repo and cwd):** `<state root>/sessions/`, `<project>/closed/`, `<project>/delivery.log` and `<project>/guard.json`. `guard.json` is written only by `scripts/guard-apply.sh` (candidate `<project>/guard.candidate.json`, `guard-write.sh diff`, then `guard-apply.sh <candidate> --repo R`; its own permission ask rule, user level, is my yes - no `--confirmed` flag); the hooks also block removing or moving the state root, any parent of it, a project state dir or `sessions/` (with a reason that says so), and hard-linking protected files (`ln`, `link`, `cp -l`). Stage 0 runs `guard-write.sh verify`. Known limits of this protection: a skill script is exempt from the hooks, the yes is the permission prompt on `guard-apply.sh` (needs the ask rule from `install-hooks.sh apply`; without it nothing asks); interpreters (`python3 -c`), `tar -x -C <state dir>` and other directory-level copies, `find -delete`, `rsync --link-dest` and `xargs rm` are not stopped; ****Re-check the sandbox design after a Claude Code update:** `scripts/probe-sandbox.sh <new scratch dir>` (about 40 short Haiku runs; `--list`, `--only id,id`, `--modes`; needs an outside-`/tmp` dir, default `~/.cache/dt-probes/probe-sandbox/<scratch name>`) runs the property list (auto-allow, deny and ask rules, `denyWrite` and renames outside `/tmp`, excluded scripts and the `cd` / `&&` forms, the gate scripts' prompts with the sandbox on and off, `settings.local.json` by Bash, network, localhost server and client, `git branch -m`, `gh` / `glab` forms, the installer block); exit 0 all PASS, 1 a FAIL, 3 CHANGED (different from the last probe), 4 INCONCLUSIVE. `docs/sandbox-dry-run.md` is the TUI checklist that counts the prompts that are not gates on `main` vs `v0.2`. **Settings are changed by the user, not by Claude:** `install-hooks.sh apply|uninstall|project-apply|project-uninstall|project-sandbox-apply|project-sandbox-off` (the writing subcommands; `status`, `diff`, `selftest`, `project-status`, `project-diff`, `project-sandbox-status|diff` stay allowed) are blocked by the hook in every spelling and repo - with the sandbox off nothing else would stop an auto-mode run. The user runs them in their own terminal tab after reading the matching diff (not `!`: whether it passes through hooks is unverified, probe V4). Known limit: `python3 -c` that imports the installer. **Gate scripts (`guard-apply.sh`, `ticket-state.sh`) run only as `<skill dir>/scripts/<name>.sh <args>` (G1):** the permission ask rule on that full path is the user's yes, so `bash <script>`, `python3 <script>`, a relative path, a wrapper, an env assignment, `bash -c` and the backing modules (`guard_apply.py`, `ticket_ctl.py ticket-state`) are blocked by the hook; a case variant of the script or of a path component (`GUARD-APPLY.sh`, `.CLAUDE`, `DELIVER-TICKET`) reaches the same file on a case-insensitive filesystem but not the literal ask rule, so only the exact spelling is allowed, in every repo (a call that names these scripts also starts the no-state check). The stage texts must therefore call them by that absolute path (1d step 4). **Program names are compared lower-case (C3):** on a case-insensitive filesystem `GIT push` and `RM -rf` run git and rm, so every rule folds the name; a gated command must still be written in lower case. **Gated commands are spelled one way (S1):** the ask rules match the command text as a prefix, and with the sandbox on a command they miss would run auto-approved, so the hook blocks `git push` unless it is literally `git push <remote> <branch>` (no `-C` / `-c` / `--git-dir`, no path, no `env` / `command` / `xargs` / env assignment in front, not inside `bash -c` / `eval` / `$( )`), and the same for `gh pr create` and the `gh` / `glab` write list below (an option between the subcommand words, such as `gh pr --repo o/r edit 1`, is blocked; `-R` / `--repo` first is covered by its own ask rule). Init does not suggest a git host for `allowedDomains` unless the user asks: with an HTTPS remote and its host allowed, a push that the ask rule missed could otherwise run sandboxed. The `glab` / `gh` write commands are an enumerated ask list at USER level (`install-hooks.sh apply`: a project without the sandbox has no project block, and auto mode would let the classifier run them), and the sandbox leaves only those forms plus four narrow reads (`pr view|list`, `mr view|list`) out of the sandbox (`excludedCommands`); any other `gh` / `glab` form stays sandboxed, where the Go TLS check fails (probe V8) - it fails closed, or in a project without the sandbox follows the normal permission flow. Because an ask rule always beats an allow rule (docs), so a broad `gh *` ask with narrow allows cannot work. Probed with a fake `gh` / `glab` (Claude Code 2.1.311, 2026-11-11): covered (prompt) are the plain form, `-R` / `--repo` first, an env prefix (`FOO=1`, `GH_REPO=...`), an absolute path, `/usr/bin/env`, a double space, `cd x && ...`, `echo a; ...`, `api`, `auth`; **not covered: an option between the subcommand words (`gh pr --repo o/r edit 1`)**, any `gh` / `glab` alias or extension that wraps a write, and a script that calls them; `-R` / `--repo` also makes reads prompt. `command gh ...` is stripped by Claude Code as a wrapper (docs) but the model rewrote it in the probe, so it is untested. **Known limits until milestone 1c (plan.md, "Milestone 1c plan"):** (#1, fixed in C4) the push hook no longer runs `verify.on_push`: stage 4 runs `scripts/verify-record.sh` (sandboxed, clean worktree only) which writes `evidence/<ID>/verify.json` (HEAD tree, exit code and sha256 of each command); the hook reads it and blocks when it is missing, failed, or for another tree or command, and fails closed when no ticket resolves from the cwd, when any pushed source ref has another tree than the record, and when the sources cannot be determined (`--tags`, wildcards, deletes, `push.default=matching`, a configured `remote.<r>.push`). The record is tamper-evident, not tamper-proof: `evidence/` is sandbox-writable, so Claude could write a forged one (stage 8 check: C10). UX change: the tests no longer run at the push prompt; what you see is the stage 4 record. (F1, fixed in C5) the excluded `git push` / `git branch -m` ran the repo's own hooks (`pre-push`, `reference-transaction`; probed 2026-11-16: they fired from a `core.hooksPath` inside the work tree and from `<git-common-dir>/hooks`, and with the sandbox on they wrote outside `allowWrite`) unsandboxed. Now neither is excluded and the hook blocks Claude's plain `git push` / `git branch -m`; push and rename are `scripts/git-push.sh <remote> <branch>` (permission prompt = your yes) and `scripts/git-rename.sh <old> <new>` (excluded, no prompt), which validate their own arguments (no options, allowed remote name only, plain branch name, scrubbed `GIT_*` environment, refusal when a risky git config key such as `core.sshCommand` or a `remote.*.receivepack` comes from a file inside the repo or a worktree) and run git with `core.hooksPath=/dev/null`. Trade-off: the team's own `pre-push` and `reference-transaction` hooks do not run on Claude's pushes or renames; put what `pre-push` checks into `verify.on_push`. (C5b) The scripts trust `~/.gitconfig` and `~/.config/git/**` (and `$XDG_CONFIG_HOME/git/**`), so the hooks block Write / Edit and shell writes to them and `git config --global|--system|--file <those>` writes (reads stay allowed), and `install-hooks.sh apply` adds them to the user-level sandbox `denyWrite`; a risky key from any other file under your home (an `[include]` of `~/.gitconfig-work`, say) is refused by the scripts. Like the `~/.claude` rule this holds only in a repo with delivery state (A2b). Unverified: a sandboxed plain push over SSH (it should fail; only `file://` outside `allowWrite` was probed). **A2b:** in a directory without delivery state the `~/.claude` rule does not run, so the hooks, the skill's scripts and `settings.json` are writable as far as these hooks go (the harness permission prompt is the only backstop there; blocking it would also block building the skill from its own repo). To switch them off for one project only, move that project's `guard.json` away (a state dir without `guard.json` counts as "not initialised").

## Change settings

Re-run `/deliver-ticket init` in the project's main checkout and name the group(s) to change (re-run mode: it shows the current values, changes only the groups you name, regenerates `guard.json` and re-runs the hook checks). Editing `config.md` by hand also works; stage 0 then warns that `config.md` is newer than `guard.json`, and an init re-run regenerates it. Naming nothing = full refresh of `project.md`.

Groups and the default init proposes when it finds nothing better: Org policy / Decision-makers / Tracker / MR adapter: none (you answer; Delivery log off until answered; adapter `manual` if the glab check fails) · Project type, Verify, Git: detected from the repo and confirmed · Definition of Done: the template's list · Workspace: worktree per ticket, max 3 parallel in tier B/C and 5 in total, ports base 3100 step 10 · Verify timeout 300 s · Stage-0 checks: the 9 in `stages/0-environment.md` · Autonomy: tier B stop `before-push`, tier C `local` · Language `en`/`en` · Time tracking off. Changing the stage-0 checks means editing `stages/0-environment.md` (see Extending).

## Extending (add a file, don't edit the core)

| To add | Add | Touch |
|---|---|---|
| a tracker / MR adapter (GitHub, Jira, GitLab Issues, a messaging connector) | `adapters/<name>.md` implementing the four calls (check / create / update / comments) as in `adapters/manual.md` | the init MR group may list it (one line) |
| an ecosystem profile (Python, Go, ...) | `profiles/<name>.md` in the format of `profiles/node.md`: detect signals, where the commands are, watch globs, each row with its evidence or marked unverified | nothing else: init picks the profile whose detect signals match, and `scripts/project-map-stale.sh` reads the `dt:` lines of every profile (no script edit) |
| a stage or a check inside a stage | `stages/<N>-<name>.md`, or a numbered item in the existing stage file | one row in the table in `SKILL.md` section 4 |
| a template | `templates/<name>.md` | the stage that uses it |
| a hook that **replaces** a Claude Code default (e.g. `WorktreeCreate`) | register it per project (`PROJECT_SPECS` in `scripts/install_hooks.py`), never at user level; test it by comparing with behaviour **without** the hook (a test that only checks "a worktree was created" missed that `.worktreeinclude` stopped being copied) | `tests/run-installer.sh` |
| any hook change | add a test with a session that has **no open ticket** next to the ticket-session case (the first guard version blocked every session in an initialised repo and was only tested inside a ticket) | `tests/run-hooks.sh` |
| a hook rule (new block) | a branch in `hooks/dtcore.py` (`check_cmd`, `check_search`, ...) | **and** its tests in `tests/run-hooks.sh`: cases that must block and cases that must pass |
| a script | `scripts/<name>` | a test in `tests/` |

After **any** change: run `tests/run-guard-json.sh`, `tests/run-hooks.sh <new dir>`, `tests/run-worktree-create.sh <new dir>`, `tests/run-installer.sh <new dir>`, `tests/run-project-map.sh <new dir>`, `tests/run-compare.sh <new dir>`, `tests/run-base-worktree.sh <new dir>`, `tests/run-classify.sh <new dir>`, `tests/run-pending-ticket.sh <new dir>`, `tests/run-session-ctl.sh <new dir>`, `tests/run-transcript-reads.sh <new dir>`, `tests/run-branch-name.sh <new dir>`, `tests/run-docs-lint.sh` (all must end `fail=0` / `pass`), and re-run the classification evals (`evals/`) when stage 1, `classify.py` or the risk definitions changed. Then one line in `CHANGELOG.md`.

## Global permission rules that `apply` adds (user level, all projects)

- `ask`: `Bash(git push:*)` and `Bash(git branch -m:*)` (second layer: the hook blocks plain `git push` / `git branch -m` first), `Bash(<skill dir>/scripts/git-push.sh *)`, `Bash(glab mr create:*)`, `Bash(gh pr create:*)`.
- `deny`: `Bash(glab mr merge:*)`, `Bash(gh pr merge:*)`, `Read(**/.env*)`.

**Merging through `glab`/`gh` is denied in every project, on purpose** (decision 2026-11-05: merges are done in the GitLab UI). Anyone who needs `glab mr merge` from the CLI must remove that rule by hand or run `install-hooks.sh uninstall`. `Read(**/.env*)` covers the Read tool only; whether it also stops the built-in Grep/Glob tools is unverified (`docs/phase5-checklist.md`).

## Tests (never touch real settings or state)

```sh
tests/run-guard-json.sh                        # guard.json validator
tests/run-hooks.sh <new scratch dir>           # hook dry runs (ticket session vs no-ticket session, bind hook, protected bookkeeping)
tests/run-worktree-create.sh <new scratch dir> # worktree-create, setup-worktree, env-keys, port-lock race
tests/run-installer.sh <new scratch dir>       # apply + uninstall on a copy of settings.json restores it byte for byte
tests/run-project-map.sh <new scratch dir>     # project.md freshness: A/D/R vs M, advance sha, lazy rescan, propose-init
tests/run-compare.sh <new scratch dir>         # pre-existing vs new failure lines
tests/run-classify.sh <new scratch dir>        # tier floor: risk globs raise it, risk.exclude (test files) never does
tests/run-branch-name.sh <new scratch dir>     # final branch name from guard.json branch_naming (slug rules, unknown placeholders, existing branches)
tests/run-docs-lint.sh                         # static checks that the skill's instructions contain the backlog fixes (writes nothing)
tests/run-transcript-reads.sh <new scratch dir> # eval rule check: tool calls touching docs (with/without slash) + searches for the ticket outside code paths (real dry-run commands as cases)
tests/run-pending-ticket.sh <new scratch dir>  # ticket input saved before init, taken after it
tests/run-session-ctl.sh <new scratch dir>     # session-map.sh (pause/rebind) and ticket-state.sh (done/cancelled/reopen) + effect on the guard
tests/run-probe-sandbox.sh <new scratch dir>   # scripts/probe-sandbox.sh against a fake claude: case table, verdicts (PASS / FAIL / CHANGED / INCONCLUSIVE), exit codes, argument checks
tests/run-guard-write.sh <new scratch dir>     # guard-write.sh (diff/verify) and guard-apply.sh: backup, log line, candidate renamed, v0.1 file adoption, hooks let only the scripts write guard.json
tests/run-base-worktree.sh <new scratch dir>   # shared detached _base worktree: acquire / move / lock / dirty / main checkout untouched
tests/run-install.sh <new scratch dir>         # scripts/install.sh with a fake HOME: n / empty input write nothing, y applies + backup + status, wrong clone path refused
tests/run-evals.sh <new scratch dir>           # phase-6 eval tooling (truth.json, runner, scorer) against a fake `claude`; starts no real session
```
