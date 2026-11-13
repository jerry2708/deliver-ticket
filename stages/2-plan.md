# Stage 2 - Plan + plan check

Gate: tier A (runs as B in v0.1): see 1-intake; **B and C: me**. Work in the ticket's worktree. Plan from the normalised ticket only, never the raw text.

## Before exploring the code
Read `<state>/project.md` and the files under its "Knowledge sources" (link, don't copy) first; they say where things are and which commands exist. A section marked `stale: yes` is rescanned **only if the ticket's planned area touches it** (read the code it describes, rewrite the section with sources, then `<skill dir>/scripts/project-map-stale.sh mark-checked <state>/project.md --guard <state>/guard.json "<section>"`); other stale sections are left alone and listed. The ban on searching repo notes for the ticket (`1-intake.md`, Input rules) holds here too; technical docs by API or symbol are fine. **Code is the truth:** where `project.md` contradicts the code, trust the code, say so in the plan, and fix that section. No `project.md` -> explore as usual and say so.

## Plan
Write the plan into the ticket file (`tickets/<ID>.md`, section "Plan") and stop for my approval. Do not use plan mode (`EnterPlanMode` / `ExitPlanMode`): plan mode writes its plan under `~/.claude/plans/`, which the guard blocks (dry runs 2 and 3); its exit dialog switches the session to default mode; its "approved" came back although I had seen no plan (dry run 3), so it is never my approval. Only my written answer at the gate is. The plan must have:
- **Steps** in build order; a big task is cut into chunks: spikes first, risky parts separate, vertical slices (each chunk runnable and checkable).
- **Per step:** files to touch, the AC(s) it serves, the test that proves it. Supporting steps (scaffolding, refactor, tooling) are labelled `support: <AC>`.
- **Every assumption about existing contracts** (function signatures, API shapes, data formats) cited with `file:line` after you read it, found by an uncut search (SKILL.md section 6); unread = marked `unverified`.
- **Waiting ACs** shown as parked (not planned, with the open question); everything else is planned.
- **Planned file list** and a size estimate: Size is re-judged now. Over M (>10 files or >400 lines) -> propose several MRs with `templates/plan-split.md` (each MR deployable, ACs traced); I confirm the split.
- **Bugs:** the root cause, cited `file:line`, and the failing test that will prove it (stage 3 writes it first).
- **Risk re-check:** re-judge all 9 categories with the planned file list; the tier can only go up. Raise it -> stop and tell me (reason, new gates). Categories flagged `risk re-check at stage 2` from intake are resolved here.
- **Stop point and commits:** per tier and config; soft mode caps at `local`.

## Plan check (read-only, before showing the plan)
Build a small table and put it in the ticket file:
- **Tier B:** AC -> plan step(s) -> test(s). An AC with no step or no test is flagged.
- **Tier C:** also step -> AC (a step with no AC and no `support:` label is scope creep) and conflicts with CLAUDE.md / the common DoD (**critical**).
- Tier A/no plan gate: a critical finding -> stop and ask; others are listed.
Fixes to the plan only after my OK; tell me what you would change.

## Gate
Show: plan (steps), plan-check table, risk re-check result, tier (unchanged or raised), stop point, parked ACs. Stop and wait. On approval: `stage: 3`, `next: Read <skill dir>/stages/3-build.md`.
