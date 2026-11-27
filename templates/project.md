# Project knowledge - <project name>

Facts about the codebase, not decisions. Decisions live in `config.md`; things learned from tickets live in `lessons.md`. Written by `/deliver-ticket init` from its scan, kept in the state dir (never in the repo). **Every line has a source** (`file:line` or the command that produced it); a line without one is a guess and does not belong here. Env files: names only. Code is the truth: if a line contradicts the code, trust the code, fix the line.

Each section starts with its freshness line (`<skill dir>/scripts/project-map-stale.sh`):
`checked: <sha> · <date> · watch: <globs>` then `stale: no`. Format is exact: the script parses it.

## Project map
checked: <sha> · <date> · watch: <globs>
stale: no
- <app/package> - <what it is> (`<path>`; source)
- entry points, routes/handlers, agents + tools, stores/DB (source for each)

## Commands
checked: <sha> · <date> · watch: <globs>
stale: no
- lint / test / build / e2e / dev: `<command>` (source)

## Ports
checked: <sha> · <date> · watch: <globs>
stale: no
- <service> <port> (source)

## Env files
checked: <sha> · <date> · watch: <globs>
stale: no
- `<path>`: key names via `<skill dir>/scripts/env-keys.sh <file> --repo <repo_root>` (names only)

## Risk-path findings
checked: <sha> · <date> · watch: <globs>
stale: no
- <category>: <glob> -> <files matched today, count> (source: CLAUDE.md / rules / layout)

## Existing hooks
checked: <sha> · <date> · watch: <globs>
stale: no
- <hook> (`<settings file>:<line>`) - what it does

## Tool-config gaps
checked: <sha> · <date> · watch: <globs>
stale: no
- <tool> - <file> - <what is missing for `.claude/worktrees/`> (reported, never edited)

## Knowledge sources
Read before exploring code. Link, do not copy.
- `CLAUDE.md` (+ nested `apps/*/CLAUDE.md`), `.claude/rules/*.md`
- `docs/`, READMEs
- an existing code graph or index, if the project has one (used if present, never installed)
