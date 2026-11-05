# Fresh-context AC check - prompt for the subagent

You get only: the AC table, the evidence files listed in it, and the diff. You do not get the build conversation.
For every AC: is there real evidence that the behaviour holds (a test that fails without the change, a response, a screenshot, a log)? Reply in <= 15 lines:
- AC<n>: confirmed / not confirmed - one line why (cite the evidence file or `file:line`).
- Anything in the diff that no AC asks for.
Do not fix anything. Change your mind only on new evidence.
