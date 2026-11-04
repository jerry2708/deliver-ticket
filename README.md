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

# 3. last resort, no scripts: delete the entries whose "command" contains
#    /.claude/skills/deliver-ticket/hooks/ from ~/.claude/settings.json by hand
```

The hooks do nothing in a repo without delivery state (`~/.local/share/deliver-ticket/<project-key>/guard.json`). To switch them off for one project only, move that project's `guard.json` away (a state dir without `guard.json` counts as "not initialised").

## Tests (never touch real settings or state)

```sh
tests/run-guard-json.sh                        # guard.json validator
tests/run-hooks.sh <new scratch dir>           # hook dry runs
tests/run-worktree-create.sh <new scratch dir> # worktree-create, setup-worktree, env-keys, port-lock race
```
