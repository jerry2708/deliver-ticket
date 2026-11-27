# Stage 6 - Security

Checks are tied to **Risk categories, not the tier**: run the check for every category judged `yes` at stage 1 (re-judged at stages 2 and 3), also when I lowered the tier. Gate: **C: me**. Tier B: no stop here; the findings go to the final review. Categories all `no` -> record "no risk category yes" and continue.

## Per category
- **Auth / payment / irreversible actions** (tier C): I review them myself - show exactly the changed code and the control flow, `file:line`.
- **Personal data:** only the fields needed; none in logs; none in evidence that leaves the machine; field list from `guard.json` `risk.personal_data_fields`.
- **Per-user server API or store:** the user identity comes **server-side from the authenticated session/credential, never from request input** (path, query, body, header the client controls). **Cross-user evidence:** identity B asking for identity A's resource is refused. Preferred: an automated test with two mocked identities. Otherwise I check by hand with two test accounts (config `Two test identities`; fake data) and you record the result. You never type passwords; a real sign-in is mine.
- **AI agent action with side effects:** approval is enforced **in code**, not only in the prompt; the arguments shown to the user = the arguments executed; deny or timeout -> nothing changes. Approval by a chat reply is stated in the review as "not enforced by code".
- **Migration:** reversible or not, data loss, order with the code deploy, a shared DB (config) that other worktrees use.
- **New dependency:** why needed, maintained, license, install scripts; lockfile diff reviewed.
- **Infra config:** what runs with it, who can change it, secrets in it.
- **Secrets in the diff, logs, evidence:** `<skill dir>/scripts/secret-scan.sh <ID> --guard <state>/guard.json` (its own Bash call; sandboxed, no prompt). It scans `evidence/<ID>/`, the lines the ticket adds against the base branch, uncommitted changes and untracked files, never `.env*`, and prints each finding masked (`<where>:<line> <kind> <first 4 chars>... (<length>)`). Exit 1 -> show its lines and judge each: a real secret -> stop and tell me (never print or copy the value); a false positive -> say why. Exit 2 -> show the error; the check is `unverified`. Do not grep for key patterns yourself: grep prints the value, and a credential-pattern search in the state dir needs a prompt (DRY-02). A clean scan is a heuristic, not proof.

## Output
A table: category, yes/no, check run, result, evidence, open items. Anything not verifiable is `unverified` (never pass). `stage: 7`, `next: Read <skill dir>/stages/7-commit-mr.md`. Tier C: stop and wait.
