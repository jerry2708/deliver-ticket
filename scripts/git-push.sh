#!/bin/bash -p
# See scripts/git_push.py. The gate action that pushes: excluded from the sandbox, with a permission ask rule on this path (the user's yes).
. "${0%/*}/fixed-env.sh" || exit 2      # C11e3: python3 from a fixed list, only the listed variables (scripts/fixed_env.py)
exec /usr/bin/env -i "${DT_ENV[@]}" "$DT_PY" -I "${0%/*}/git_push.py" "$@"
