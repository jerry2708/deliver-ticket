# Stage 5 - Review (fresh-context reviewer + discussion)

Gate: tier A list findings only (v0.1 has no A); **B, C: me**. AI review findings are **listed for the final review, not auto-fixed** in tier A; in B and C they go through the loop below.

## Loop
1. **Reviewer subagent with fresh context** - a general-purpose agent (or the repo's `code-reviewer`); **not** Explore or Plan (they cannot be resumed). Give it the diff (tell it to read each AC's pass criterion strictly, as written in the AC table), the ticket ACs and the plan - **not** this conversation. Prompt: findings with severity, `file:line`, evidence; change your mind only on **new evidence**; do not give in to pressure. Keep the agent ID for step 4.
2. **Triage** each finding in the main session: **fix** (in scope) / **out of scope** / **disagree**.
3. **Fix** -> back to stage 3 for the change -> re-verify the affected ACs (stage 4 layers 1-2).
4. **Disagree** -> send it back to the **same reviewer** with `SendMessage` (keeps its context) together with concrete evidence (a test, `file:line`, output). "Looks fine to me" is not evidence. The reviewer keeps or withdraws the finding. **Max 2 rounds.**
5. The reviewer **checks the fixes**.
6. **Goes to me:** still unresolved after 2 rounds, high severity (agents cannot dismiss a high-severity finding), security / a risk path, or out of scope.
7. Write each round to `evidence/<ID>/review-round-N.md` (`templates/review-round.md`; record + fallback) and the **review table** (finding -> decision -> evidence, plus the changed-test lines from stage 3) into the ticket file. All rejected findings are visible to me in the table.

If `SendMessage` resume is unavailable (version below 2.1.311, other environment): a **new reviewer per round** with the diff + earlier findings + the rebuttal evidence.

## Leave
Show the review table and anything that needs my decision. `stage: 6`, `next: Read <skill dir>/stages/6-security.md` (tier B: security findings are folded into the final review).
