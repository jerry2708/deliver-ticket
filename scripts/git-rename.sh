#!/bin/bash -p
# See scripts/git_rename.py. Renames the ticket's own branch: excluded from the sandbox (bookkeeping: allow rule, no prompt), repo hooks off.
. "${0%/*}/fixed-env.sh" || exit 2      # C11e3: python3 from a fixed list, only the listed variables (scripts/fixed_env.py)
exec /usr/bin/env -i "${DT_ENV[@]}" "$DT_PY" -I "${0%/*}/git_rename.py" "$@"
