#!/bin/bash -p
# See scripts/guard_apply.py. The gate action that writes <state>/guard.json: excluded from the sandbox, with a permission ask rule on this path.
. "${0%/*}/fixed-env.sh" || exit 2      # C11e3: python3 from a fixed list, only the listed variables (scripts/fixed_env.py)
exec /usr/bin/env -i "${DT_ENV[@]}" "$DT_PY" -I "${0%/*}/guard_apply.py" "$@"
