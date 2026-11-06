# <ID> - <title>
skill: <absolute path of this skill>/SKILL.md
stage: <0|1|1b|2|3|4|5|6|7|8>
next: Read <skill dir>/stages/<file>.md
state: active   <!-- active | waiting | split | waiting for review | done | cancelled -->
mode: normal    <!-- normal | soft -->
tier: provisional <A|B|C>   <!-- confirmed <tier> after the gate; "classified A, run as B (v0.1)" when A -->
stop_point: <local | before-push | draft-mr | ready-mr>
worktree: <none | absolute path under <repo>/.claude/worktrees/<ID>>
branch: <none | name>
ports: <none | PORT=... lines>
tracker_id: <none | alias>
depends_on: <none | IDs>
parent: <none | ID>   <!-- children of a split only -->
children: <none | IDs>   <!-- split parent only -->

## Goal
## User story
## Acceptance criteria
<!-- AC1: Given ... When ... Then ...   ·   PROPOSED - not in source marks anything the source does not state  ·  waiting ACs: [WAITING: Q1] -->
## Out of scope
## Open questions
<!-- Q1 (affects AC2) asked <date> to <role>: ... -->
## Parked work
## Dependencies - linked, not read
## Clarifications log
<!-- - <date> Q: ... -> A: ... (who) -> changed: AC2, out of scope -->

## Intake
- Verdict: <go | stop (DoR) | split>   DoR met / missing: ...
- Bug verdict (bugs only): ... severity ... confidence ...
- Coverage scan: (category: Clear/Partial/Missing, one line each)
- Accepted gaps (confirmed at the gate): ...

## Classification
| Category | yes/no/unknown | Source (quote or file:line) |
|---|---|---|
| risk paths | | |
| auth | | |
| payment | | |
| personal data | | |
| migration | | |
| new dependency | | |
| infra config | | |
| per-user server API or store | | |
| AI agent side effects | | |
- Size: <S|M|L> (estimated) · Clarity: ... · Type: ...
- Tier: provisional ... confirmed ... (reasons; every change logged below)

## Plan
## Plan check
## Build log
<!-- files, commits, test changes: test -> AC -> reason -->
## AC -> evidence
## Review table
## Security table
## Log
<!-- - <date> stage N: ... (tier changes, escalations, my redirects, soft-mode notes) -->

## Original ticket text (unchanged)
