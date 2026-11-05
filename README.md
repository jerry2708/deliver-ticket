# deliver-ticket (personal skill)

`/deliver-ticket init | <ticket-id|file> | <ID> cancel`. Run it only by typing it. Design rationale: `docs/plan.md`.

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

# 3. last resort, no scripts: delete the entries whose "command" contains
#    /.claude/skills/deliver-ticket/hooks/ from ~/.claude/settings.json (and from <repo>/.claude/settings.local.json) by hand
```

The hooks do nothing in a repo without delivery state (`~/.local/share/deliver-ticket/<project-key>/guard.json`). To switch them off for one project only, move that project's `guard.json` away (a state dir without `guard.json` counts as "not initialised").

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
| a hook rule (new block) | a branch in `hooks/dtcore.py` (`check_cmd`, `check_search`, ...) | **and** its tests in `tests/run-hooks.sh`: cases that must block and cases that must pass |
| a script | `scripts/<name>` | a test in `tests/` |

After **any** change: run `tests/run-guard-json.sh`, `tests/run-hooks.sh <new dir>`, `tests/run-worktree-create.sh <new dir>`, `tests/run-installer.sh <new dir>`, `tests/run-project-map.sh <new dir>`, `tests/run-compare.sh <new dir>`, `tests/run-base-worktree.sh <new dir>`, `tests/run-classify.sh <new dir>`, `tests/run-pending-ticket.sh <new dir>` (all must end `fail=0` / `pass`), and re-run the classification evals (`evals/`) when stage 1, `classify.py` or the risk definitions changed. Then one line in `CHANGELOG.md`.

## Global permission rules that `apply` adds (user level, all projects)

- `ask`: `Bash(git push:*)`, `Bash(glab mr create:*)`, `Bash(gh pr create:*)`.
- `deny`: `Bash(glab mr merge:*)`, `Bash(gh pr merge:*)`, `Read(**/.env*)`.

**Merging through `glab`/`gh` is denied in every project, on purpose** (decision 2026-11-05: merges are done in the GitLab UI). Anyone who needs `glab mr merge` from the CLI must remove that rule by hand or run `install-hooks.sh uninstall`. `Read(**/.env*)` covers the Read tool only; whether it also stops the built-in Grep/Glob tools is unverified (`docs/phase5-checklist.md`).

## Tests (never touch real settings or state)

```sh
tests/run-guard-json.sh                        # guard.json validator
tests/run-hooks.sh <new scratch dir>           # hook dry runs
tests/run-worktree-create.sh <new scratch dir> # worktree-create, setup-worktree, env-keys, port-lock race
tests/run-installer.sh <new scratch dir>       # apply + uninstall on a copy of settings.json restores it byte for byte
tests/run-project-map.sh <new scratch dir>     # project.md freshness: A/D/R vs M, advance sha, lazy rescan, propose-init
tests/run-compare.sh <new scratch dir>         # pre-existing vs new failure lines
tests/run-classify.sh <new scratch dir>        # tier floor: risk globs raise it, risk.exclude (test files) never does
tests/run-pending-ticket.sh <new scratch dir>  # ticket input saved before init, taken after it
tests/run-base-worktree.sh <new scratch dir>   # shared detached _base worktree: acquire / move / lock / dirty / main checkout untouched
```
