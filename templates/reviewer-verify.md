# Fresh-context AC check - prompt for the subagent

You get only: the AC table, the evidence files listed in it, and the diff. You do not get the build conversation.
For every AC: take the pass criterion as written in the table (it must be the AC's own words) and read it strictly - an either/or criterion passes only through the branch that happened, and an outcome that is neither branch is not confirmed. Is there real evidence that the behaviour holds (a test that fails without the change, a response, a screenshot, a log)? Reply in <= 15 lines:
- AC<n>: confirmed / not confirmed - one line why (cite the evidence file or `file:line`).
- Anything in the diff that no AC asks for.
Do not fix anything. Change your mind only on new evidence.
Tools: read-only (no file writes, no git state changes); one plain command per Bash call (a pipe into `head` / `wc` / `sort` is fine; no chains, heredocs or `{ ... }` groups); absolute paths, never `cd <dir> && ...`; no inline code (`node -e`, `python3 -c`). What you cannot check by reading or by the project's existing test command: say `unverified` and what would settle it.
