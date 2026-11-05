# Profile: node (hints for init, never facts)

Loaded by `init.md` when a Node manifest is found (`package.json`). It only proposes values and where to look; every value is shown as a finding and becomes config after I confirm it. No match for the project -> no profile: init asks everything, as without profiles.

Written from what `copilot-kit-training` shows (the evidence column). Rows marked **unverified here** are general convention that no repo seen so far confirms; check them on first use and fix this file.

## Detect
| Signal | Means | Evidence |
|---|---|---|
| `pnpm-lock.yaml`, or `"packageManager": "pnpm@..."` in the root `package.json` | package manager pnpm | `package.json:27` (`pnpm@10.26.2`), `pnpm-lock.yaml` present |
| `yarn.lock` -> yarn, `package-lock.json` -> npm, `bun.lock` / `bun.lockb` -> bun | other managers | **unverified here** |
| `pnpm-workspace.yaml` (`packages: apps/*, packages/*`) and/or `"workspaces"` in the root `package.json` | monorepo; apps under `apps/`, libraries under `packages/` | both present, `package.json:5-8` |
| `turbo.json` | root scripts go through turbo (`lint` = `turbo run lint`, `dev` = `turbo dev`, `build` = `turbo build --filter=!agent`) | `turbo.json`, `package.json` scripts |

## Where the commands are
- Root `package.json` `scripts`: `dev`, `build`, `lint`, `format`, plus app-specific ones (`build:agent`, `build:all`). Run with the detected manager (`pnpm <script>`).
- Per-app `apps/<app>/package.json` `scripts`: `test` (vitest), `lint` (eslint), `build`, `dev`, `e2e` (Playwright). Run one app with `pnpm --filter <app> <script>` (`CLAUDE.md:11-17`).
- Some apps define `pretest` / `predev` / `prebuild` that build a shared package first (`apps/agent/package.json`, `apps/web/package.json`): the first run of a script is slower than the script suggests.
- A script missing in `package.json` (here: no typecheck) is "none", not a guess.
- Test file location: `include` in `vitest.config.ts` per app (`src/**/*.test.ts`); e2e in `apps/web/e2e/`.

## Install and worktrees
- Install command: `<manager> install` (README `pnpm install`). A fresh worktree has no `node_modules` and no `.husky/_`; this repo already installs on the first `git commit` in a worktree through `.claude/hooks/ensure-worktree-deps.sh` (existing hook: report it, do not duplicate it).
- Env files to link into worktrees: the repo may list them (`.worktreeinclude`: `apps/web/.env.local`, `apps/agent/.env`); otherwise names come from `ls -a` + `scripts/env-keys.sh`, never contents.
- Ports: `next dev` and `mastra dev` defaults are 3000 and 4111 as README / CLAUDE.md state (`README.md:88-90`); how a port is overridden without editing `.env` is **unverified here** - do not guess a variable name, ask.

## Tool configs that may scan `.claude/worktrees/` (init checks, reports gaps, never edits)
`vitest.config.*` (`include`, root), `eslint.config.*` (`ignores`), `tsconfig*.json` (`include`/`exclude`), `.prettierignore`, dev-server watch settings (`next.config.*`).

## Watch globs for `project.md` sections (freshness, `scripts/project-map-stale.sh`)
| Section | Suggested watch |
|---|---|
| Commands, Ports | `package.json`, `apps/*/package.json`, `turbo.json`, `pnpm-workspace.yaml` |
| Project map | `apps/*/src/**`, `packages/*/src/**` (adjust to the real layout) |
| Env files | `.worktreeinclude`, `apps/*/.env*` (names only; file existence, never contents) |
| Existing hooks | `.claude/settings*.json`, `.husky/**` |
| Tool-config gaps | `*.config.*`, `tsconfig*.json`, `.prettierignore` |

## Risk-path hints (the user confirms each glob after seeing its matches)
Manifests and lockfiles -> new dependency (`**/package.json`, `pnpm-lock.yaml`); CI and `.claude/` -> infra config. Other categories come from CLAUDE.md / the code layout, not from this profile.

## Machine-readable (read by `scripts/project-map-stale.sh`; one line per key, comma-separated)
Do not add prose between these lines. Meaning of each key: header of `scripts/project_map_stale.py`. A new profile adds its own lines; no script edit.
dt:config-files: next.config.*, vite.config.*, vitest.config.*, jest.config.*, playwright.config.*, eslint.config.*, mastra.config.*, turbo.json
dt:json-keys: package.json=scripts
dt:lockfiles: pnpm-lock.yaml, package-lock.json, yarn.lock, bun.lock, bun.lockb
dt:workspace-files: pnpm-workspace.yaml, nx.json, lerna.json
dt:app-roots: apps, packages, services, libs, modules
