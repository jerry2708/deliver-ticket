#!/bin/bash
# See scripts/base_worktree.py. The shared detached _base worktree for stage-4 base runs: excluded from the sandbox (bookkeeping: allow rule, no prompt),
# arguments validated, repo hooks off, no install (setup-worktree.sh <repo> <_base> _base runs that inside the sandbox).
exec python3 -I "$(dirname "$0")/base_worktree.py" "$@"
