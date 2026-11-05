# Cancel - `/deliver-ticket <ID> cancel`

Cancel from any stage. Only the ticket ID is the command; any other second word is pasted text, not this.

1. Read the ticket file (state, stage, worktree, branch, MR). Missing -> say there is no such ticket and stop.
2. Ask for the **reason** if I did not give one; set `state: cancelled`, with reason + date, in the ticket file. Do not change anything else of the ticket.
3. **Nothing is deleted.** List what exists: the worktree path, the local branch, the remote branch (only if one was pushed), the port block, the evidence dir. Tell me the exact commands for cleanup and ask which I want you to run. The shared `_base` worktree (`.claude/worktrees/_base`, stage 4 triage) belongs to no ticket: it is listed once at the end of the build and removed only on my explicit OK. Order: leave the worktree first (`ExitWorktree` with keep), then `git worktree remove <path>` from the main checkout, then `git branch -d <branch>` (never `-D` without my explicit word). Run each only after I confirm that item.
4. **Open MR:** draft a closing comment; I post it and close the MR. Never post it yourself.
5. **Split parent:** list its children and their states; cancelling a parent does not cancel children - ask.
6. One lesson line (project `lessons.md`): why it was cancelled and at which stage.
