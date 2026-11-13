# Stage 1b - Workspace (worktree)

Runs only **after the stage-1 gate** (I confirmed ticket + tier), never merged into stage 0 or 1. Gate: none. A ticket with state `split` (parent) gets no worktree; each child gets its own.

One worktree per ticket is the only mode: a ticket built in the main checkout could not write any code (the guards block it), and several tickets run in parallel.

## Do
1. Re-read the ticket file (tier, stop point, mode) and `guard.json` (`base_branch`, `branch_naming`, `env_files`, `install`, `ports`).
2. Call `EnterWorktree` with `name` = the ticket ID (a child: `<ID>-<n>`), nothing else. The project-level `WorktreeCreate` hook (registered by init in `<repo>/.claude/settings.local.json`; `scripts/install-hooks.sh project-status --repo <main checkout>` says whether it is) creates `<repo>/.claude/worktrees/<ID>`: branch per the naming rule from the **configured base branch** (local ref), env files symlinked from the main checkout (never copied, never read), dependency install, a port block. The session is now inside the worktree.
2b. **Hook not registered** (init step 3b declined): Claude Code creates the worktree itself (branch `worktree-<ID>` from its own base, `.worktreeinclude` files copied). Tell me that the branch name and base are not the configured ones, then run `scripts/setup-worktree.sh <repo_root> <worktree> <ID>` (env links, install, port block) and record its output.
2c. **Final branch name.** The hook knows only the ticket ID, so the branch it made is provisional (type `work`, no slug, for example `work/retro-7`). Before the first commit build the full name with `scripts/branch-name.py <guard.json> <ID> <type> "<slug words>" --repo <repo_root>` (type from the confirmed ticket Type: bug -> `fix`, feature -> `feat`, refactor -> `refactor`, tests -> `test`, docs / wording / chore -> `chore`; slug words = the goal in at most 5 words) and rename: `git branch -m <provisional> <final>` run from the worktree directory (a plain git call, never `git -C`: it stays sandboxed and the half-done rename of a sandboxed run is a known failure; if the session is not in the worktree, `cd` there in a separate call first). Exit 3 (the name exists locally) or 4 (it exists as a remote-tracking ref) -> stop and ask me. Record the final name as `branch:`.
3. If `EnterWorktree` fails or the hook printed an error, show the error and stop. Typical causes: branch of that name already exists on a remote (same ticket started elsewhere - ask me), base branch missing, install failed (the hook removed what it created). Never create the worktree by hand with `git worktree add`, and never fall back to the main checkout.
4. Record in the ticket file: `worktree:` absolute path, `branch:`, base branch, the port block (read `<state>/ports/<ID>`, lines `VAR=port`), `stage: 1b` -> `next: Read <skill dir>/stages/2-plan.md`. Write the ticket file with the Write tool at its state path (not inside the worktree).
5. Check the hook's work with read-only commands: `git -C <worktree> status --short` is clean, `git -C <worktree> rev-parse --abbrev-ref HEAD` is the branch, env links exist (`ls -l`, names only - never open them).
6. Remote branch check: the hook looks at remote-tracking refs only (no network). If I want the real remote checked, say so; otherwise note "remote not checked".
7. Ports: the dev server of this ticket always gets its ports on the command line (`PORT=<n> <command>`); never edit `.env`. Before any server start, stage 4 checks that the port is free or owned by this worktree.

## Leave
Tell me: worktree path, branch, ports, anything that needs my attention (a dev-server watcher in the main checkout that may scan `.claude/worktrees/`, a shared DB that this ticket's migrations could clash with). Continue to stage 2.
