# Eval report v0.1 - classification evals (phase 6), 2026-11-09/10

Scope: stage 1 only (intake verdict, DoR, provisional tier) on the **8 retro rows** of `evals/sample-tiers.md`, 3 rounds, 45 jobs
(`scripts/run-evals.py`, `scripts/score-evals.py`; one fresh `claude -p --permission-mode auto` session per job, auto memory off,
stopped at the first gate). Stages 2-8 are covered by the dry runs (`docs/phase5-checklist.md`), not by this eval.

## Framing
The ground truth is my judgement, written in advance (`evals/truth.json`, derived from `sample-tiers.md`); it is not an objective fact.
The value of the eval is: the rule bugs it exposes, stability across rounds, and no tier below my floor. 8/8 verdicts is a **review
signal, not a hard gate**: a miss is read and either fixes a rule or corrects the ground truth (logged with date and reason).

## What changed during the eval (read this before the numbers)
| When | Change | Why |
|---|---|---|
| after the 2 pilots | stage 1: DoR item 2 is met only by ACs in the ticket or confirmed by the decision-maker (the "no source to draft from" escape is gone); bundling (`split`) is checked before the DoR, each part goes through the DoR on its own | pilot: RETRO-5 got `go` with drafted ACs and tier B; RETRO-8 got `stop (DoR)` instead of `split` |
| after the pilots | split row scored on structure only (verdict, 3 parts, child IDs, AC table, no parent tier, no worktree); part tiers deferred to 6b | a part that fails the DoR gets no tier |
| after round 1 | ground truth Retro #2 B -> C ("changed from B to C after the round 1 run", 2026-11-09): the bulk move is agent-only (`use-commerce-cart-tools.tsx:255-263`, rule `stages/1-intake.md:63`) | consistent with Retro #7 and WL-05 |
| after round 1 | stage 1: the DoR questions always go in the final message (no questions file); every question follows the template; PROPOSED drafts must be confirmed in a question of their own; bug tickets ask for repro and expected vs actual. Rubric reworded (a draft the message asks to confirm covers an item) | round 1: questions were a file in some runs and a message in others; one-liners; drafts never confirmed |
| after round 1 | scorer fixes (group PROPOSED heading, `ls .claude/worktrees` is REVIEW, usage-limit label); after rounds 2-3: part names with backticks, multi-line commands, `worktree: none <!-- ... -->`, `Q1` style question headings | scorer false positives |

**Round 1 is the baseline before the stage 1 rule changes of round 1's review; stability is measured on rounds 2-3.** Rounds 2-3 ran with the
same rules and the same scorer version, except the scorer fixes listed last, applied when re-scoring.

## Results (re-scored with the final scorer)
Verdict: **8/8 rows correct in all 3 rounds** (7 x `stop (DoR)`, RETRO-8 `split`). Tier below my floor: **0**. Tier above: 1
(`r3-RETRO-5-fixture` C, truth B), at the 1/8 limit. Safety violations: 0. INVALID runs: 1 (`r3-RETRO-5-intake`, see limits).
Failed runs (incl. rubric): 8 of 45. **SIGNALS: not all met.**

Per row (intake status / rubric `covers_all` and superfluous question numbers / fixture tier):
| Row | Round 1 (baseline) | Round 2 | Round 3 |
|---|---|---|---|
| RETRO-1 (B) | fail, cov=F, sup [2,3] / B | fail, cov=F, sup [3] / B | ok, cov=T / B |
| RETRO-2 (C) | fail, cov=F / C | review, cov=T / C | fail, cov=F / C |
| RETRO-3 (C) | review, cov=T / C | review, cov=T / C | review, cov=T / C |
| RETRO-4 (C) | review, cov=T / C | fail, cov=T, sup [5] / C | review, cov=T / C |
| RETRO-5 (B) | review, cov=T / B | review / B | INVALID (real worktree) / **C** |
| RETRO-6 (B) | ok, cov=T / B | review, cov=T / B | fail, cov=T, sup [5] / B |
| RETRO-7 (C) | ok, cov=T / C | review, cov=T / C | fail, cov=T, sup [1] / C |
| RETRO-8 split | ok | review | review |

`review` = shape or transcript-reads items for a human (missing "recommended" in a question, a flagged call), not a failure.

## Stability (rounds 2-3)
- Verdicts: identical in every round and every row. The fixture tier is the same in all 3 rounds for 6 of the 7 fixture rows (RETRO-5: B, B, C).
- The C in `r3-RETRO-5-fixture` is the "depends on design" rule (a shared schema change would reach the payment path, so provisional C plus a
  question), not a read of the real worktree: that run shows no mention of `.claude/worktrees/RETRO-5` (0 hits in its stream).
  `r1-RETRO-5-fixture` did: a repo-wide grep listed files under the real `.claude/worktrees/RETRO-5` (fixed code) in its tool results.
- `unknown` risk categories per run, rounds 1/2/3: RETRO-3 3/0/0, RETRO-4 5/3/4, RETRO-5 1/1/1, RETRO-2 0/0/1, others 0. RETRO-3/4 unknowns are
  design dependent and not stated plainly in the ticket (reviewed: fine).
- Rubric: `covers_all` true in 5 of 7 DoR rows in round 1 (baseline), 6 of 7 in round 2 and 6 of 7 in round 3 (RETRO-2 is false in rounds 1 and 3, RETRO-1 in rounds 1-2).
  The superfluous-question flags move between rows and rounds ([5] on RETRO-4 in round 2, on RETRO-5 and RETRO-6 in round 3), so they are
  not a stable property of any row. **The LLM grader's calls have not been reviewed by me**; treat them as a signal.
- RETRO-2 (all rounds): the questions are design decisions after the skill drafted two ACs. In round 3 the grader accepts goal and AC
  (drafts with a confirm request) and expected vs actual, and marks only the repro steps as not clearly asked.

## Cost and time
45 jobs: **$18.17**, about 108 s per job (intake 101 s, fixture 117 s), about 81 minutes serial; two cut attempts (usage limit, HTTP 429)
cost about $0.8 more and were re-run from fresh homes (never scored). Per job about $0.40.

## Limits (known)
1. **Eval IDs collide with finished real tickets.** `RETRO-5` and `RETRO-7` have worktrees and branches in the main checkout (dry runs). The
   skill checks for an existing worktree by ticket ID: `r3-RETRO-5-intake` warned about it and read inside it (INVALID, real);
   `r2-RETRO-5-intake` was first flagged by a scorer false positive and is not shown to have read it (not checked further). An eval design flaw, not a skill bug. **Phase 6b must use IDs that collide with nothing.**
2. The scorer reads tool *inputs* only. A repo-wide search can list paths under a finished worktree in its *results*
   (`r1-RETRO-5-fixture`); that contamination is not detected.
3. WL-01..06 are not measured (phase 6b): the base branch already contains the wishlist, so a session answers "already built". 6b needs a
   pre-WL-01 checkout with its own init and `project.md`.
4. The split row is scored on structure only; part tiers wait for 6b with per-part fixtures.
5. The ground truth is one person's judgement; one project, one model, 8 tickets, 3 rounds. Run-to-run variance exists (RETRO-5 tier, rubric).
6. Reply language varies (config `chat_language: vi`; some runs reply in English). The scorer is language independent, the keyword
   cross-check is skipped for Vietnamese. Recorded, not fixed.
7. Some runs listed the repo's `docs/` (`ls ... docs`) while looking for `tickets/`: REVIEW items of `transcript-reads.py`, not searches for the ticket. Recorded, not fixed.
8. The usage limit of `claude -p` (exit 1, result `subtype: success`, `is_error: true`, `api_error_status: 429`) cut two jobs; the runner stopped,
   labelled it and continued on the next call.

## What goes to v0.2
- Override log as the real-world measure of the tier rules (count and direction of my overrides at the gate, with reasons).
- Phase 6b: WL rows on a pre-WL-01 checkout, non-colliding eval IDs, per-part fixtures for the split row, a second project type before tier A.
- Scorer: read tool results for worktree contamination; review the grader against my own reading on a sample.
- Stage 0 should not need to list `.claude/worktrees` or read an existing worktree to check the parallel limit (or the eval should hide them).
- Question template compliance and reply-language consistency as stage 1 checks.
