#!/bin/bash -p
# See scripts/base_worktree.py. The shared detached _base worktree for stage-4 base runs: excluded from the sandbox (bookkeeping: allow rule, no prompt),
# arguments validated, repo hooks off, no install (setup-worktree.sh <repo> <_base> _base runs that inside the sandbox).
. "${0%/*}/fixed-env.sh" || exit 2      # C11e3: python3 from a fixed list, only the listed variables (scripts/fixed_env.py)
exec /usr/bin/env -i "${DT_ENV[@]}" "$DT_PY" -I "${0%/*}/base_worktree.py" "$@"
