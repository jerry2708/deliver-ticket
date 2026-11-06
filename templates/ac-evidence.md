# AC -> evidence - <ID>

| AC | Pass criterion (verbatim from the AC) | How verified (test name / manual step) | Result | Evidence | Gap |
|---|---|---|---|---|---|
| AC1 | "<exact words of the AC>" | | pass / fail / unverified / waiting | evidence/<ID>/... | missing / partial / contradicts / - |

Unrequested changes (diff changes no AC asks for): <file:line - justify or remove>
Layers run: 1 automated [ ] · 2 table [ ] · 3 real run [ ] · 4 regression [ ] (per tier)
Rules: the criterion is the AC's own words and is read strictly (an either/or AC passes only through the branch that happened; neither branch = fail; ambiguous = unverified + question); unverified is never pass; "done" in a task list or commit message is not evidence.
