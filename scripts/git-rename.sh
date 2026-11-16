#!/bin/bash
# See scripts/git_rename.py. Renames the ticket's own branch: excluded from the sandbox (bookkeeping: allow rule, no prompt), repo hooks off.
exec python3 -I "$(dirname "$0")/git_rename.py" "$@"
