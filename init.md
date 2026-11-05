# init - first-run setup per project

`/deliver-ticket init` records this project's facts once, so tickets don't re-ask them. Re-run it to change settings. It detects what it can, shows it, and I confirm or edit. Re-read `SKILL.md` section 2 (hard rules) first.

## Rules

- **Detected is a finding, not a fact.** READMEs, compose files and package scripts go stale. Show every detected value as a finding with its source (`file:line`); it becomes config only after I confirm it.
- **Never read `.env*` contents** - `.env.example` too, and by any means (`Read`, `cat`, `cut`, `grep`, `head`, `awk`). Env key names come only from `scripts/env-keys.sh`. If it is missing or fails, leave the key names `<ASK>` and say so; don't work around it.
- **Never invent a value.** Org-policy and decision-maker answers have no default: leave `<ASK>` in `config.md` and ask. A field left `<ASK>` that a ticket run needs makes that run stop and ask.
- **Ask only what applies.** Groups that only some projects have (local DB, e2e, mobile simulator, signed-in browser, two test identities) are asked only when detected; otherwise one "not found" line for me to confirm.
- **The config never overrides CLAUDE.md.** Read the repo's `CLAUDE.md` and `.claude/rules/` first; where the config would conflict, report it and let me decide. CLAUDE.md wins.
- **Writes are limited to** the project state dir, `.git/info/exclude` (via `scripts/setup-exclude.sh`; local, never committed) and - last, after my yes - `~/.claude/settings.json` through `scripts/install-hooks.sh`. Nothing else in the repo changes. Tool configs (jest, eslint, tsc, watchers) are checked and gaps are reported, never edited.
- **Profiles give hints, `project.md` gives facts, `config.md` gives decisions.** Don't mix the three.
- **Group the questions.** Show all findings in one table first, then ask what is missing in batches (one batch per group below), not one question at a time.

## Preconditions

1. Inside a git repo, in the **main checkout**. Inside a ticket worktree (`.claude/worktrees/`) -> stop and say so.
2. Compute the project key (`SKILL.md` section 3). Print it and the state dir.
3. State dir already has `config.md` -> **re-run mode**: show current values, change only the groups I name, then regenerate `guard.json` (step 2) and re-run steps 3-4 (step 3 only detects).
4. If CLAUDE.md or `.claude/rules/` names risk paths, protected files or forbidden actions, collect them now (they feed the Risk group).
5. **Profile (hints only).** Look for a manifest in the repo root and its apps (`package.json`, ...). A match in `profiles/` (today: `profiles/node.md`) -> read it and use its "where to look" and "watch globs" as hints for the groups below; show each value it proposes as a finding like any other and wait for my confirmation. No match -> no profile, ask every group as written. A profile never sets a value by itself.

## Step 1 - detect and confirm, group by group

For each group: look in the places given, show findings, ask what is left, write the answer into the matching section of `config.md` (template: `templates/config.md`). Order matters: later groups use earlier answers.

| Group | Look in | Ask | Default |
|---|---|---|---|
| **Org / client policy** | `CLAUDE.md`, README, repo docs | AI use allowed and limits; Delivery log in MRs on/off; may the shared config be committed to the repo at `.claude/delivery/config.md`; where ticket text and evidence may be stored | none - must be answered. Delivery log **off** until answered |
| **Decision-makers** | - | who decides requirements (me / lead / BA / PO / PM / client); channel (tracker comment, Slack, email) | none |
| **Tracker** | repo remote host, CONTRIBUTING, branch/commit history for ID patterns | which tracker; ID format (naming and links only; tickets arrive by paste or file in v0.1) | none |
| **Project type** | package/build files, folder layout | web FE / BE-API / job-worker / CLI-library / mobile / mixed; how to run locally; which real-run tool gives evidence (browser, curl, run the command) | detect + confirm |
| **Verify** | `package.json` scripts, Makefile, CI files, CLAUDE.md | lint / test / build / e2e commands; which run on push (build only if fast); dev ports and how a port is overridden without editing `.env`; env file names; stage-0 checks; **repo without tests**: (a) add tests for changed logic or (b) real run + "no automated tests" stated in the MR; **only if the Risk group maps a per-user server API/store**: how to get two test identities through the project's own auth (mocked identities in tests preferred; otherwise two test accounts I use by hand - you never type passwords) | (a) for pure logic, (b) otherwise |
| **Definition of Done** | CLAUDE.md | edit the common list: lint/build/tests green, regression scope, no secrets, risk areas reviewed | default list in the template |
| **Git** | `git remote -v`, `git branch -a`, recent commit messages, commitlint/husky config | **base branch** (every ticket branch starts from its latest commit, not `origin/<default>`); branch naming; push remote; allowed and forbidden remotes; commit convention | detect + confirm |
| **Workspace + parallel** | `git worktree list`, ignore files, `.worktreeinclude`, tool configs | worktree per ticket (only mode in v0.1); env files to symlink (names only; **if the repo has `.worktreeinclude`, read it as that list and show it for confirmation instead of asking**; the skill symlinks them, it does not copy; no such file -> ask); dependency install command; port variables and the per-ticket port block; max parallel (3 in tier B/C + 5 total) | defaults shown |
| **DB / shared resources** (only if detected) | `docker-compose*.yml`, `.env.example` key names via `env-keys.sh`, migration folders, README | does a local DB exist; how it runs (Docker, shared, remote); safe to share across worktrees (seed data, migrations) or one per ticket. Nothing found -> one line "no local DB found", I confirm | shown as findings |
| **MR** | remote host, `glab auth status` | adapter (`gitlab-glab` / `manual`); target branch; labels; turn glab telemetry off (`GLAB_SEND_TELEMETRY=0`) - say that glab sends a usage event to the GitLab host by default | `manual` if the adapter check fails |
| **Risk** | CLAUDE.md, `.claude/rules/`, code layout | see "Risk mapping" below | thresholds from the template |
| **Autonomy** | - | per tier: commit model (`batched` = no commit in stage 3 and one commit gate in stage 7 / `each` = ask before every commit); final stop point. Check CLAUDE.md for commit/push rules first - it wins, record the conflict and how the table satisfies it | table in the template |
| **Hooks + permissions** | `~/.claude/settings.json` and `<repo>/.claude/settings*.json` (hooks only), git hooks (husky, lint-staged, pre-commit), formatter, CI config | which verify commands run on push; existing hooks that may interact; whether a formatter exists (the formatter is the project's job) | detect + show |
| **Language** | - | `chat_language`, `docs_language` | `en` / `en` |
| **Time tracking** | - | off / on (stage timestamps only) | off |

Workspace checks that need commands (read-only): `git worktree list`; whether `.claude/worktrees/` is already in `<git-common-dir>/info/exclude`; for each tool config found (jest/vitest roots and ignores, eslint ignores, `tsc` include/exclude, dev-server watch settings) whether it already ignores `.claude/`. Defaults seen on 2.1.311: vitest, jest and eslint scan `.claude/worktrees/`, `tsc` skips it - so expect gaps. Report gaps in a table (tool, file, what to add). Don't edit.

### Risk mapping

The mapping turns "risk" into globs that `classify.py` and the hooks can read. It only raises the floor: a path with no match is **not** "no risk" - at every stage you still judge each category yourself.

Categories (key in `guard.json`): `risk_paths`, `auth`, `payment`, `personal_data`, `migration`, `new_dependency`, `infra_config`, `per_user_server_api_or_store`, `ai_agent_side_effects`. Plus `labels` (tracker labels that force tier C), `personal_data_fields` (names), `thresholds`, and `exclude` (globs, default `**/*.test.*` and `**/*.spec.*`: files matching them never count as a risk path, so a test-only change does not raise the tier; I confirm the list).

1. Propose a glob list per category from the code layout (route/handler folders -> per-user API; agent tool folders -> AI action with side effects; migration folders; manifests and lockfiles -> new dependency; CI and `.claude/` -> infra config; auth folders -> auth). Show each glob with the files it matches today (`ls` / glob, a count and 2-3 examples) so I can judge it.
2. A category that doesn't apply (no payments, no AI agent) -> `N/A`, only after I confirm. A category that applies but has no known path -> `[]`.
3. Risk paths and protected areas named in CLAUDE.md / `.claude/rules/` are always included. If they conflict with what I say, report it; CLAUDE.md wins.
4. Definitions you will apply later (also in `stages/1-intake.md`): *personal data* = fields that identify a real person; *per-user server API or store* = a server-side interface or store keyed by user identity (creating one or changing its handler/auth/schema/filtering -> C, calling an existing one unchanged -> B); *AI agent action with side effects* = an action an AI agent can cause on its own that writes or deletes user data or changes an external system, human approval doesn't lower it.
5. Re-running init re-proposes the mapping. Drift later (a category judged yes on a file no glob matches -> propose a glob; glob matches but judged no -> floor stays, only I lower it with a reason) is handled in the ticket stages.

## Step 2 - write the project state

Only after step 1 is confirmed. Create the state dir and, in this order:

1. `<state>/config.md` from `templates/config.md` with my answers (if I allowed committing the shared config: `<repo>/.claude/delivery/config.md` instead, and a pointer line in the state dir; if the client forbids it, it stays in the state dir). Anything unanswered stays `<ASK>`. `config.local.md` (personal overrides) is created empty with a header.
1b. `<state>/project.md` from `templates/project.md`, filled from this scan: project map (apps/packages, entry points, routes/handlers, agents + tools, stores/DB), commands, ports, env file names (names only), risk-path findings, existing hooks, tool-config gaps, and the Knowledge sources list (CLAUDE.md and nested ones, `.claude/rules/`, `docs/`, READMEs, an existing code graph if any - links, not copies). Every line has a source (`file:line` or the command); no source -> leave the line out. Each section gets `checked: <short sha of the base branch> · <date> · watch: <globs>` (profile watch globs as the start; adjust to the real layout) and `stale: no`. Decisions stay in `config.md`; learned things stay in `lessons.md`. It never goes into the repo. Re-run mode with nothing named = full refresh of `project.md` (rewrite all sections and `checked:`).
2. Run `scripts/setup-exclude.sh --check`; if it says missing, show me the line (`.claude/worktrees/`) and the file (`<git-common-dir>/info/exclude`), and on my yes run `scripts/setup-exclude.sh`. (Don't edit that file any other way - editors and the harness refuse it.) Local git metadata only; `.gitignore` is never touched.
3. `<state>/guard.json` - what the hooks read. Fields and meaning:

| Field | From | Used by |
|---|---|---|
| `version` | `1` | all |
| `project_key`, `repo_root` | computed; absolute main-checkout path | all hooks (main-checkout write block) |
| `base_branch`, `branch_naming` | Git group | `worktree-create.sh` |
| `remotes.push`, `remotes.allowed`, `remotes.forbidden` | Git group | `guard.sh` (push to a remote not in `allowed`, or in `forbidden` -> block) |
| `verify.lint/test/build/on_push/timeout_sec` | Verify group | `verify-on-push.sh`, stage 3-4 |
| `env_files` | Workspace (names relative to the main checkout) | `setup-worktree.sh` (symlinks) |
| `install` | Workspace | `setup-worktree.sh` |
| `ports` `{vars, base, step}` | Workspace | `setup-worktree.sh`, stage 1b |
| `allowlist_extra` | extra writable paths I name (usually `[]`) | `guard.sh`, `worktree-guard.sh` |
| `stop_points`, `commit_gate` (`batched`\|`each` per tier) | Autonomy | stages 3, 7 |
| `max_parallel` `{tier_bc, total}` | Workspace | stage 0 |
| `risk` `{categories, labels, personal_data_fields, thresholds, exclude}` | Risk group | `classify.py` |

   Write it as JSON with no comments, then validate: `python3 <skill>/scripts/validate-guard.py <state>/guard.json`. Exit code must be 0. **Never leave an invalid `guard.json`** - hooks treat an unreadable state as "block everything in this repo". Fix and re-validate, or delete only your own half-written file after asking me.
4. Show me a summary: every `<ASK>` still open, every conflict with CLAUDE.md, every tool-config gap.

## Step 3 - hooks and permissions (once per machine)

Hooks are user-level (`~/.claude/settings.json`) so they also apply after a resume. They are no-ops in repos without delivery state, which is why this step comes after step 2.

1. `scripts/install-hooks.sh status` - exit 0 means every hook and permission rule is already registered correctly on this machine (later projects stop here and go to step 4).
2. Otherwise `scripts/install-hooks.sh diff` prints the exact change to `~/.claude/settings.json` (hooks with `timeout` and `"onFailure": "block"`, permission rules: ask `git push`, `glab mr create`, `gh pr create`; deny `glab mr merge`, `gh pr merge`, `Read(**/.env*)`). Show me the **whole diff**, say that the file is backed up first, and ask for my yes.
3. Only on my yes in this conversation: `scripts/install-hooks.sh apply --confirmed`. It backs up the file, writes, and is idempotent. Never write the settings any other way.
4. I decline -> **soft mode**: no hooks, no permission rules; stop point capped at `local` for every tier; ask before every commit; hard rules repeated at the start of each stage; set `soft_mode: on -> effective stop: local` in `config.md` (Hooks section; the Autonomy table stays as my choice and is not edited) and tell me what that means. `guard.json` `stop_points` is generated from the effective values: all `local` while `soft_mode: on`, the Autonomy table otherwise. The config-vs-`guard.json` comparison (stage 0, re-run) applies this override first, so `soft_mode: on` with `local` everywhere is expected, not drift; a later init that succeeds sets `soft_mode: off` and regenerates `guard.json` from the table.
5. If the script doesn't exist or fails, say so and stop; don't write the file yourself. Treat the project as soft mode until a later init succeeds, and say that.

## Step 4 - self-test

Two parts; both must pass.

**A. Harness (you run it; it proves Claude Code runs the hooks in this session)**
1. Run a Bash call whose command is exactly `echo DELIVER_TICKET_SELFTEST` - it must be **blocked** by a hook.
2. Write a file `~/.claude/.deliver-ticket-selftest` - it must be **blocked** (the guards protect `~/.claude/`).

Both blocked -> pass: then set `soft_mode: off`, the Hooks section lines (installed, self-test date) and the autonomy-table `stop_points` in `guard.json` - these follow from steps 3-4 even in a re-run where I named only other groups to change (a previous `soft_mode: on` is stale once hooks and self-test pass). Not blocked right after install -> ask me to start a new session and re-run the test there. Still not blocked -> soft mode (as in step 3.4).

**B. Script** - `scripts/install-hooks.sh selftest` prints one line per check and exits 0 only if all pass: registration complete (every entry has `timeout` and `onFailure: block`); each hook given a synthetic payload from a repo **without** delivery state exits 0 fast; the same hook given malformed JSON in a repo **with** state blocks; `session-start.sh` for a known session returns the re-orientation text.

Write the result and date into the `Hooks and permissions` section of `config.md`.

## Step 5 - report

Say: what was written and where (paths, including `project.md` and which profile was used, if any), what is still `<ASK>`, tool-config gaps, whether hooks are installed and the self-test passed (or soft mode and why), and the next command (`/deliver-ticket <ID or file>`). Don't start a ticket.
