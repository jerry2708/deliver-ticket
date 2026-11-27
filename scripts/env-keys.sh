#!/bin/bash -p
# Print the KEY NAMES of an env file, never the values: env-keys.sh <env file> --repo <main checkout>. See scripts/env_keys.py (strict checks; C11h: bookkeeping,
# excluded from the sandbox; the repo comes from the delivery state's guard.json, never from .git on disk).
. "${0%/*}/fixed-env.sh" || exit 2      # C11e3: python3 from a fixed list, only the listed variables (scripts/fixed_env.py)
exec /usr/bin/env -i "${DT_ENV[@]}" "$DT_PY" -I "${0%/*}/env_keys.py" "$@"
