# Delivery config - <project name>

Written by `/deliver-ticket init` on <date>. Edit by hand or re-run init. After editing, regenerate `guard.json` (stage 0 warns when this file is newer than `guard.json`).
`<ASK>` = not answered yet. Never fill it with a guess; init asks, and a ticket run that meets `<ASK>` in a field it needs stops and asks.
Detected facts are marked `(detected, confirmed <date>)`; anything unconfirmed is `(finding)` and is not used as fact.

## Org / client policy
- AI use allowed, and limits: <ASK>
- Delivery log in MRs: off   <!-- stays off for client projects until answered -->
- Shared config may be committed to the repo (`.claude/delivery/config.md`): <ASK>
- Where ticket text and evidence may be stored: <ASK>

## Decision-makers
- Requirements decided by: <ASK>   <!-- me / lead / BA / PO / PM / client -->
- Channel for questions: <ASK>   <!-- tracker comment / Slack / email -->

## Tracker
- Tracker: <ASK>
- Ticket ID format: <ASK>   <!-- naming and links only; tickets arrive by paste or file in v0.1 -->
- Child ticket suffix: -n

## Project
- Type: <ASK>   <!-- web FE / BE-API / job-worker / CLI-library / mobile / mixed -->
- How to run locally: <ASK>
- Real-run tool and evidence (stage 4): <ASK>

## Verify
- lint: <ASK>
- test: <ASK>
- build: <ASK>
- e2e: <none / command>
- Run on push (verify-on-push): <ASK>   <!-- keys among lint/test/build; build only if fast -->
- Verify timeout (seconds): 300
- Dev ports / how overridden without editing `.env`: <ASK>   <!-- e.g. `PORT=3001 pnpm dev` -->
- Env files (names only, never contents): <ASK>
- Env key names the real run needs: <ASK>   <!-- from <skill dir>/scripts/env-keys.sh <file> -->
- Stage-0 checks: <ASK>
- Repo without tests: (a) add tests for changed logic / (b) real run + "no automated tests" in the MR - chosen: <ASK>
- Two test identities (only if a per-user server API/store is mapped in Risk): <ASK>   <!-- mocked identities in tests preferred -->

## Definition of Done (common part)
- lint, build and tests green
- regression scope: <ASK>
- no secrets in the diff, logs or evidence
- risk areas reviewed (stage 6, per Risk category judged yes)
- <project-specific items>

## Git
- Base branch (every ticket branch starts from its latest commit): <ASK>
- Branch naming: <ASK>   <!-- e.g. feature/{id}-{slug} -->
- Push remote: <ASK>
- Allowed push remotes: <ASK>
- Forbidden remotes: <ASK>
- Commit convention: Conventional Commits   <!-- unless the project says otherwise -->

## Workspace and parallel
- Mode: worktree per ticket (the only mode in v0.1), root `<repo>/.claude/worktrees/<ID>`
- `.git/info/exclude` has `.claude/worktrees/`: <yes/no>
- Env files linked into each worktree (names): <ASK>
- Dependency install command: <ASK>
- Port variables and block: <ASK>   <!-- e.g. PORT, AGENT_PORT; base 3100, step 10 -->
- Max parallel tickets: 3 in tier B/C, 5 in total
- Main-checkout tools that pick up worktrees (jest/vitest roots, eslint ignores, tsc include, dev-server watchers): <findings; gaps are reported, never edited>

## DB / shared resources
<!-- only if detected; otherwise one line: "no local DB found (confirmed <date>)" -->

## MR
- Adapter: <ASK>   <!-- gitlab-glab / manual -->
- Target branch: <ASK>
- Labels: <ASK>
- glab telemetry off (`GLAB_SEND_TELEMETRY=0`): <ASK>

## Risk
Paths below are globs; they only raise the floor. A path with no match is not "no risk": Claude still judges every category from the ticket and the code.
- risk paths (touching one -> tier C): <ASK>
- auth: <ASK>
- payment: <ASK>   <!-- "N/A" if the project has none -->
- personal data (paths): <ASK>
- personal-data fields: <ASK>
- migration: <ASK>
- new dependency (manifests, lockfiles): <ASK>
- infra config: <ASK>
- per-user server API or store: <ASK>
- AI agent action with side effects: <ASK>   <!-- "N/A" if no AI agent -->
- excluded from every risk glob (a change to only these files never raises the tier): <ASK>   <!-- propose **/*.test.*, **/*.spec.* -->
- tracker labels that force tier C: <ASK>
- Sources merged in: CLAUDE.md, `.claude/rules/` <!-- conflicts reported; CLAUDE.md wins -->
- Thresholds: S <=3 files, <=5 ACs, <=100 lines; M <=10 files, <=400 lines; L above M -> split into several MRs. Lines exclude lockfiles, generated code and tests.

## Autonomy
| Tier | Gates with me | Commits (`commit_gate`) | Final stop point |
|---|---|---|---|
| A (v0.1: runs as B) | ticket + tier, final review, commit set (stage 7) | batched: none in stage 3, one gate in stage 7 (diff + all planned messages, one yes) | before-push |
| B | ticket + tier, plan, final review, commit set (stage 7) | batched (as A) | before-push |
| C | every stage | each: ask before every commit | local |

CLAUDE.md conflict check: <record any CLAUDE.md rule on commits/pushes and how this table satisfies it; CLAUDE.md wins>

## Hooks and permissions
- Hooks installed on this machine (`scripts/install-hooks.sh status`): <yes/no, date>
- Self-test passed: <date / failed -> soft mode>
- soft_mode: off   <!-- on -> effective stop: local for every tier (overrides the Autonomy table; guard.json is generated to match) -->
- Existing hooks found (user + project settings, git hooks, formatter, CI): <findings>

## Language
- chat_language: en
- docs_language: en

## Time tracking
- off
